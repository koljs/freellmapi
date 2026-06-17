#!/usr/bin/env bash
# build-magisk.sh — assembles a flashable Magisk module zip for FreeLLMAPI.
#
# Pipeline:
#   1. esbuild-bundle the server (better-sqlite3 kept external)
#   2. vite-build the React dashboard
#   3. download the official Node.js linux-arm64 binary (glibc-linked)
#   4. extract glibc runtime libs from an Ubuntu arm64 rootfs
#   5. compile better-sqlite3 for arm64/linux inside a Docker container
#      (uses qemu-user-static binfmt for cross-arch on x86_64 hosts)
#   6. lay everything out under build/magisk/ and zip it up
#
# Prerequisites on the build host:
#   - Node.js 20+, npm
#   - Docker (with qemu-user-static / binfmt_misc for arm64 emulation)
#   - curl, tar, unzip, zip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/magisk"
MODULE_DIR="$BUILD_DIR/freellmapi"

# --- Config -------------------------------------------------------------------
NODE_VERSION="22.16.0"          # LTS, matches the version the server targets
NODE_ARCH="arm64"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"

# Ubuntu base rootfs — source of glibc shared libs (Android ships Bionic, not
# glibc, so the official Node.js linux-arm64 binary can't run unaided).
UBUNTU_ROOTFS_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-arm64.tar.gz"

# better-sqlite3 version — pinned to match server/package.json so the native
# module's ABI matches what the bundle expects at require() time.
BETTER_SQLITE3_VERSION=$(node -e "console.log(require('$PROJECT_DIR/server/package.json').dependencies['better-sqlite3'].replace(/^\^/,''))")

# Module version — read from server/package.json (the most-bumped of the three
# workspace packages).
VERSION=$(node -e "console.log(require('$PROJECT_DIR/server/package.json').version)")

# --- Preflight ----------------------------------------------------------------
command -v node    >/dev/null || { echo "ERROR: node not found"; exit 1; }
command -v npm     >/dev/null || { echo "ERROR: npm not found"; exit 1; }
command -v curl    >/dev/null || { echo "ERROR: curl not found"; exit 1; }
command -v tar     >/dev/null || { echo "ERROR: tar not found"; exit 1; }
command -v zip     >/dev/null || { echo "ERROR: zip not found"; exit 1; }
command -v docker  >/dev/null || { echo "ERROR: docker not found (needed to cross-compile better-sqlite3 for arm64)"; exit 1; }

echo "=== FreeLLMAPI Magisk Module Builder ==="
echo "  Module version : v${VERSION}"
echo "  Node.js        : v${NODE_VERSION} (linux-${NODE_ARCH}, glibc)"
echo "  better-sqlite3 : ${BETTER_SQLITE3_VERSION}"
echo "  Ubuntu rootfs  : 22.04 arm64 (glibc source)"
echo ""

# --- Clean + scaffold ---------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$MODULE_DIR/files/dist" "$MODULE_DIR/files/client" "$MODULE_DIR/files/native"

# --- 1. Install build deps (esbuild) -----------------------------------------
echo "[1/7] Installing build dependencies..."
cd "$PROJECT_DIR"
npm install --no-audit --no-fund --ignore-scripts

# --- 2. Bundle server with esbuild -------------------------------------------
echo "[2/7] Bundling server (esbuild, external: better-sqlite3)..."
node "$SCRIPT_DIR/bundle-server.mjs"
# bundle-server.mjs writes to build/bundle/index.mjs (a neutral location
# independent of the Magisk module layout). Copy it into the module tree
# so it lands inside the zip — service.sh loads it from $APP_DIR/dist/.
mkdir -p "$MODULE_DIR/files/dist"
cp "$PROJECT_DIR/build/bundle/index.mjs" "$MODULE_DIR/files/dist/index.mjs"

# --- 3. Build client dashboard ------------------------------------------------
echo "[3/7] Building React dashboard (vite)..."
npm run build -w client

# --- 4. Download Node.js arm64 binary ----------------------------------------
echo "[4/7] Downloading Node.js v${NODE_VERSION} linux-${NODE_ARCH}..."
NODE_TAR="$BUILD_DIR/node.tar.xz"
if [ -f "$NODE_TAR" ]; then
  echo "  Using cached $NODE_TAR"
else
  curl -fL -o "$NODE_TAR" "$NODE_URL"
fi
tar xf "$NODE_TAR" -C "$BUILD_DIR" "node-v${NODE_VERSION}-linux-${NODE_ARCH}/bin/node"
cp "$BUILD_DIR/node-v${NODE_VERSION}-linux-${NODE_ARCH}/bin/node" "$MODULE_DIR/files/node"
chmod 755 "$MODULE_DIR/files/node"

# --- 5. Extract glibc runtime from Ubuntu arm64 rootfs -----------------------
echo "[5/7] Extracting glibc runtime libs from Ubuntu arm64 rootfs..."
ROOTFS_TAR="$BUILD_DIR/ubuntu-rootfs.tar.gz"
ROOTFS_DIR="$BUILD_DIR/rootfs"
if [ -f "$ROOTFS_TAR" ]; then
  echo "  Using cached $ROOTFS_TAR"
else
  curl -fL -o "$ROOTFS_TAR" "$UBUNTU_ROOTFS_URL"
fi
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
tar xzf "$ROOTFS_TAR" -C "$ROOTFS_DIR"

LIB_DIR="$MODULE_DIR/files/lib"
mkdir -p "$LIB_DIR"
# Node.js + better-sqlite3 need: the dynamic linker, libc, libm, libdl, librt,
# libpthread (all glibc), plus libstdc++ and libgcc_s (for the C++ parts of
# better-sqlite3). Follow symlinks with -L so we get real files.
for lib in ld-linux-aarch64.so.1 libc.so.6 libm.so.6 libdl.so.2 librt.so.1 libpthread.so.0 libstdc++.so.6 libgcc_s.so.1; do
  found=$(find "$ROOTFS_DIR" -name "$lib" \( -type f -o -type l \) | head -1 || true)
  if [ -n "$found" ]; then
    cp -L "$found" "$LIB_DIR/"
    echo "  Copied: $lib"
  else
    echo "  WARNING: $lib not found in rootfs"
  fi
done
if [ ! -f "$LIB_DIR/ld-linux-aarch64.so.1" ]; then
  echo "ERROR: glibc dynamic linker missing — rootfs layout may have changed"
  exit 1
fi

# --- 6. Cross-compile better-sqlite3 for arm64/linux -------------------------
echo "[6/7] Compiling better-sqlite3 ${BETTER_SQLITE3_VERSION} for arm64/linux (Docker)..."
NM_DIR="$MODULE_DIR/files/node_modules"
mkdir -p "$NM_DIR"

# Run an arm64 Ubuntu container under qemu emulation. We install build-essential
# + python3 (node-gyp needs both), npm-install just better-sqlite3 (no native
# prebuilt binary exists for arm64/linux in npm's registry for this version,
# so node-gyp compiles from source), then copy the WHOLE node_modules out.
#
# We need the whole node_modules (not just better-sqlite3) because
# better-sqlite3's lib/database.js does `require('bindings')` at runtime —
# bindings + file-uri-to-path are its production deps and must be resolvable
# via the node_modules walk alongside better-sqlite3 itself.
#
# --platform=linux/arm64 requires qemu-user-static registered via binfmt_misc
# (on Docker Desktop and most CI runners this is set up automatically).
docker run --rm --platform linux/arm64 \
  -v "$MODULE_DIR/files:/out" \
  -e BETTER_SQLITE3_VERSION="$BETTER_SQLITE3_VERSION" \
  ubuntu:22.04 \
  bash -c '
    set -e
    apt-get update -qq
    apt-get install -y --no-install-recommends curl ca-certificates python3 make g++ > /dev/null
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1
    apt-get install -y --no-install-recommends nodejs > /dev/null
    cd /tmp
    npm init -y > /dev/null
    npm install --no-audit --no-fund --build-from-source better-sqlite3@${BETTER_SQLITE3_VERSION}
    # Copy the whole node_modules tree so both the ESM resolver (for
    # import "better-sqlite3") and the CJS resolver (for the internal
    # require("bindings") inside better-sqlite3) find their packages via
    # the standard node_modules walk at runtime.
    rm -rf /out/node_modules
    cp -r node_modules /out/node_modules
    echo "  Packages: $(ls /out/node_modules | tr '\n' ' ')"
    echo "  Native module: $(ls -la /out/node_modules/better-sqlite3/build/Release/better_sqlite3.node)"
    echo "  ELF check: $(file /out/node_modules/better-sqlite3/build/Release/better_sqlite3.node)"
  '

if [ ! -f "$NM_DIR/better-sqlite3/build/Release/better_sqlite3.node" ]; then
  echo "ERROR: better-sqlite3 native module not built"
  echo "Hint: ensure qemu-user-static is installed: docker run --rm --privileged multiarch/qemu-user-static --reset -p yes"
  exit 1
fi

# --- 7. Assemble module -------------------------------------------------------
echo "[7/7] Assembling Magisk module..."
cp "$PROJECT_DIR/magisk/module.prop"       "$MODULE_DIR/"
cp "$PROJECT_DIR/magisk/customize.sh"      "$MODULE_DIR/"
cp "$PROJECT_DIR/magisk/service.sh"        "$MODULE_DIR/"
cp "$PROJECT_DIR/magisk/post-fs-data.sh"   "$MODULE_DIR/"
cp "$PROJECT_DIR/magisk/uninstall.sh"      "$MODULE_DIR/"
chmod 755 "$MODULE_DIR/customize.sh" "$MODULE_DIR/service.sh" \
          "$MODULE_DIR/post-fs-data.sh" "$MODULE_DIR/uninstall.sh"

# Copy the built client dashboard.
cp -r "$PROJECT_DIR/client/dist/." "$MODULE_DIR/files/client/"

# Stamp the version into module.prop.
sed -i "s/^version=.*/version=v${VERSION}/" "$MODULE_DIR/module.prop"
sed -i "s/^versionCode=.*/versionCode=$(date +%s | cut -c1-10)/" "$MODULE_DIR/module.prop"

# --- Zip ----------------------------------------------------------------------
ZIP_NAME="freellmapi-magisk-v${VERSION}.zip"
cd "$MODULE_DIR"
zip -r "$BUILD_DIR/$ZIP_NAME" . > /dev/null
cp "$BUILD_DIR/$ZIP_NAME" "$PROJECT_DIR/$ZIP_NAME"

echo ""
echo "=== Build complete ==="
echo "  Module dir : $MODULE_DIR"
echo "  Module size: $(du -sh "$MODULE_DIR" | cut -f1)"
echo "  Zip        : $PROJECT_DIR/$ZIP_NAME"
echo "  Zip size   : $(du -sh "$PROJECT_DIR/$ZIP_NAME" | cut -f1)"
echo ""
echo "Install:"
echo "  adb push $ZIP_NAME /sdcard/Download/"
echo "  Then flash via Magisk Manager → Modules → Install from storage."

#!/usr/bin/env bash
# docker-build-native.sh — runs INSIDE the arm64 Ubuntu container.
# Kept as a separate file (not an inline `bash -c '...'` string) to avoid
# the quoting hell that comes from nesting $(...), single quotes, and
# double quotes inside a docker run argument.
#
# Env: BETTER_SQLITE3_VERSION — the version to compile.
# Vol: /out — the module's files/ dir; we write /out/node_modules/.
set -euo pipefail

echo "  [native] apt-get install build deps..."
apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates python3 make g++ > /dev/null

echo "  [native] installing Node.js 22 (nodesource)..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1
apt-get install -y --no-install-recommends nodejs > /dev/null

echo "  [native] node version: $(node --version)"

cd /tmp
npm init -y > /dev/null

echo "  [native] npm install --build-from-source better-sqlite3@${BETTER_SQLITE3_VERSION}..."
npm install --no-audit --no-fund --build-from-source "better-sqlite3@${BETTER_SQLITE3_VERSION}"

# Copy the whole node_modules tree so both the ESM resolver (for
# `import "better-sqlite3"`) and the CJS resolver (for the internal
# `require("bindings")` inside better-sqlite3) find their packages via
# the standard node_modules walk at runtime.
echo "  [native] copying node_modules to /out..."
rm -rf /out/node_modules
cp -r node_modules /out/node_modules

NODE_FILE="/out/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
if [ ! -f "$NODE_FILE" ]; then
  echo "  [native] ERROR: $NODE_FILE not found after build"
  exit 1
fi

echo "  [native] packages: $(ls /out/node_modules | tr '\n' ' ')"
echo "  [native] native module: $(ls -la "$NODE_FILE")"
echo "  [native] ELF check: $(file "$NODE_FILE")"

#!/system/bin/sh
#
# service.sh — launched by Magisk late-start service mode after boot.
# Runs the FreeLLMAPI Node.js server under a bundled glibc runtime (Android
# ships Bionic libc, the official Node.js linux-arm64 binary is glibc-linked).
# The process is supervised: on exit it restarts after a short backoff.

MODDIR=${0%/*}
DATA_DIR=/data/local/freellmapi
APP_DIR="$MODDIR/files"
LOG_FILE="$DATA_DIR/service.log"
PID_FILE="$DATA_DIR/freellmapi.pid"

NODE_BIN="$DATA_DIR/node"
LINKER="$DATA_DIR/lib/ld-linux-aarch64.so.1"
# $DATA_DIR/node_modules holds better-sqlite3 + bindings + file-uri-to-path,
# staged from the module dir. The ESM resolver walks up from dist/index.mjs
# and finds $DATA_DIR/node_modules/better-sqlite3; better-sqlite3's internal
# CJS require('bindings') finds $DATA_DIR/node_modules/bindings the same way.

# --- Wait for boot to settle --------------------------------------------------
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 2
done
# Network stacks (wifi/cellular) take a few more seconds to come up after
# boot_completed fires; the catalog sync + health probes tolerate failure,
# but giving them a reachable interface on first run avoids noisy logs.
sleep 10

mkdir -p "$DATA_DIR" "$DATA_DIR/data" "$DATA_DIR/lib" "$NATIVE_DIR"

# --- Stage binaries off the module mount --------------------------------------
# /data/adb/modules may be mounted noexec on some kernels, so we copy the
# node binary + glibc shared libs + better-sqlite3 native module into
# /data/local/freellmapi (which is always exec-capable) on first boot and
# refresh them whenever the staged copy is missing or older than the module.
stage_file() {
  src="$1"
  dst="$2"
  if [ ! -f "$dst" ] || [ "$src" -nt "$dst" ]; then
    cp -f "$src" "$dst"
  fi
}

if [ -f "$APP_DIR/node" ]; then
  stage_file "$APP_DIR/node" "$NODE_BIN"
  chmod 755 "$NODE_BIN"
fi

if [ -d "$APP_DIR/lib" ]; then
  for lib in "$APP_DIR/lib/"*; do
    [ -f "$lib" ] || continue
    stage_file "$lib" "$DATA_DIR/lib/$(basename "$lib")"
    chmod 755 "$DATA_DIR/lib/$(basename "$lib")"
  done
fi

# Stage the node_modules tree (better-sqlite3 + bindings + file-uri-to-path).
# Copied as a real directory (not symlinked) so the module dir can be unmounted
# or upgraded without breaking the running server's require resolution.
if [ -d "$APP_DIR/node_modules" ]; then
  rm -rf "$DATA_DIR/node_modules"
  cp -rf "$APP_DIR/node_modules" "$DATA_DIR/node_modules"
fi

# Stage the server bundle into $DATA_DIR/dist/. The bundle must live under
# $DATA_DIR (not the read-only module dir) so that Node's ESM resolver, when
# walking up from dist/index.mjs looking for node_modules/, finds the staged
# node_modules tree. ESM bare-specifier imports (e.g. `import "better-sqlite3"`)
# do NOT consult NODE_PATH — only the node_modules walk works — so the
# bundle's location and the node_modules tree must form a real package layout.
BUNDLE_DST="$DATA_DIR/dist/index.mjs"
if [ -f "$APP_DIR/dist/index.mjs" ]; then
  mkdir -p "$DATA_DIR/dist"
  stage_file "$APP_DIR/dist/index.mjs" "$BUNDLE_DST"
fi

# Sanity checks — abort cleanly if the module was installed without running
# build-magisk.sh (which would leave files/ empty).
if [ ! -x "$NODE_BIN" ]; then
  echo "[$(date '+%F %T')] FATAL: node binary missing at $NODE_BIN" >> "$LOG_FILE"
  exit 1
fi
if [ ! -x "$LINKER" ]; then
  echo "[$(date '+%F %T')] FATAL: glibc linker missing at $LINKER" >> "$LOG_FILE"
  exit 1
fi
if [ ! -f "$DATA_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
  echo "[$(date '+%F %T')] FATAL: better-sqlite3 native module missing" >> "$LOG_FILE"
  exit 1
fi
if [ ! -f "$BUNDLE_DST" ]; then
  echo "[$(date '+%F %T')] FATAL: server bundle missing at $BUNDLE_DST" >> "$LOG_FILE"
  exit 1
fi

# --- Environment --------------------------------------------------------------
# FREEAPI_DB_PATH  — relocate SQLite away from the (possibly read-only) module
#                    dir into the persistent data dir.
# FREEAPI_ENV_PATH — point dotenv at the user's .env (with ENCRYPTION_KEY).
# CLIENT_DIST      — serve the built React dashboard from the module dir.
export FREEAPI_DB_PATH="$DATA_DIR/data/freeapi.db"
export FREEAPI_ENV_PATH="$DATA_DIR/.env"
export CLIENT_DIST="$APP_DIR/client"
export NODE_ENV=production
export HOME="$DATA_DIR"

# --- Supervise ----------------------------------------------------------------
# Restart on exit with a 3s backoff. A crash loop will burn battery, but the
# only realistic exit causes are a corrupted .env or a missing native module
# — both of which are fix-in-place, not retry-out scenarios. Cap the backoff
# at 30s after 5 rapid restarts to avoid hammering a broken setup.
RESTART_COUNT=0
BACKOFF=3

echo "[$(date '+%F %T')] Starting FreeLLMAPI (pid $$)..." >> "$LOG_FILE"

while true; do
  # Write the supervisor pid so the user can `kill $(cat $PID_FILE)` to stop.
  echo $$ > "$PID_FILE"

  # Launch node via the glibc dynamic linker. --library-path makes the bundled
  # glibc libs take precedence over Android's Bionic libs for this process
  # tree only — system-wide libc is untouched.
  # Bundle is launched from $DATA_DIR/dist/ (not the module dir) so the ESM
  # resolver's node_modules walk finds the better-sqlite3 symlink.
  "$LINKER" --library-path "$DATA_DIR/lib" "$NODE_BIN" \
    "$BUNDLE_DST" >> "$LOG_FILE" 2>&1
  EXIT_CODE=$?

  echo "[$(date '+%F %T')] Process exited (code $EXIT_CODE), restarting in ${BACKOFF}s..." >> "$LOG_FILE"

  RESTART_COUNT=$((RESTART_COUNT + 1))
  if [ "$RESTART_COUNT" -ge 5 ]; then
    BACKOFF=30
  fi

  sleep "$BACKOFF"
done

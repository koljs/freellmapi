#!/system/bin/sh
#
# uninstall.sh — runs when the user removes the module from Magisk Manager.
# Kills the running service and removes the staged binaries + native module.
# The data directory (/data/local/freellmapi) is KEPT so the user's SQLite
# database, encrypted provider keys, and .env survive a reinstall. They can
# delete it manually if they really want a clean slate.

DATA_DIR=/data/local/freellmapi
PID_FILE="$DATA_DIR/freellmapi.pid"

# Stop the supervisor + its node child.
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  kill "$PID" 2>/dev/null
  # Kill any node process we spawned (matched by the app dir path).
  pkill -f "$DATA_DIR/dist/index.mjs" 2>/dev/null
  rm -f "$PID_FILE"
fi

# Remove staged binaries, the staged node_modules, and the staged bundle.
# Keep $DATA_DIR itself, $DATA_DIR/.env, $DATA_DIR/data, and $DATA_DIR/service.log.
rm -f "$DATA_DIR/node"
rm -rf "$DATA_DIR/lib"
rm -rf "$DATA_DIR/node_modules"
rm -rf "$DATA_DIR/dist"

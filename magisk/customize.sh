#!/system/bin/sh
#
# customize.sh — runs once at install time inside Magisk Manager.
# Validates the device, generates the encryption key on first install, and
# seeds the persistent data directory.

SKIPUNZIP=0
DATA_DIR=/data/local/freellmapi

ui_print "=================================="
ui_print " FreeLLMAPI Magisk Module"
ui_print "=================================="

# --- Architecture guard -------------------------------------------------------
# Only arm64-v8a is supported: the bundled Node.js binary and glibc runtime
# are linux-arm64, and better-sqlite3 is precompiled for arm64 as well.
if [ "$ARCH" != "arm64" ]; then
  abort "Unsupported architecture: $ARCH. This module requires arm64 (arm64-v8a)."
fi
ui_print "- Architecture: arm64 ✓"

# --- Android version guard ----------------------------------------------------
# Node.js 20+ requires Android 10+ (API 29) in practice — older releases lack
# the kernel/syscall surface Node's libuv loop expects.
API_LEVEL=$(getprop ro.build.version.sdk)
if [ -n "$API_LEVEL" ] && [ "$API_LEVEL" -lt 29 ]; then
  abort "Android API $API_LEVEL is too old. FreeLLMAPI requires Android 10+ (API 29)."
fi
ui_print "- Android API: $API_LEVEL ✓"

# --- Persistent data directory -----------------------------------------------
# /data/local/ is exec-capable and survives module updates; the module dir
# itself (/data/adb/modules/freellmapi) may sit on a noexec mount on some
# devices, so we keep the node binary + glibc libs + sqlite db under
# /data/local/freellmapi instead.
mkdir -p "$DATA_DIR"
mkdir -p "$DATA_DIR/data"
mkdir -p "$DATA_DIR/lib"
ui_print "- Data directory: $DATA_DIR"

# --- Encryption key -----------------------------------------------------------
# ENCRYPTION_KEY is required for startup (AES-256-GCM envelope encryption for
# provider API keys). Generate once on first install and preserve across
# upgrades — losing it makes the encrypted keys in SQLite unrecoverable.
ENV_FILE="$DATA_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  ui_print "- First install: generating ENCRYPTION_KEY..."
  # /system/bin/sh has no openssl reliably; use /dev/urandom + od.
  KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  if [ -z "$KEY" ] || [ ${#KEY} -ne 64 ]; then
    abort "Failed to generate encryption key. Aborting."
  fi
  cat > "$ENV_FILE" <<EOF
ENCRYPTION_KEY=$KEY
PORT=3001
HOST=0.0.0.0
NODE_ENV=production
EOF
  chmod 600 "$ENV_FILE"
  ui_print "  ENCRYPTION_KEY written to $ENV_FILE"
  ui_print "  IMPORTANT: back this file up. Losing it = losing all stored provider keys."
else
  ui_print "- Existing .env found, preserving ENCRYPTION_KEY."
fi

# --- Copy default .env into module dir as fallback ---------------------------
# service.sh reads FREEAPI_ENV_PATH=$DATA_DIR/.env; this in-module copy is just
# a reference template, not used at runtime.
if [ ! -f "$MODPATH/files/.env.example" ]; then
  cat > "$MODPATH/files/.env.example" <<'EOF'
ENCRYPTION_KEY=replace-with-64-char-hex
PORT=3001
HOST=0.0.0.0
NODE_ENV=production
# Optional: context handoff on model switch
# FREELLMAPI_CONTEXT_HANDOFF=on_model_switch
# Optional: request analytics retention
REQUEST_ANALYTICS_RETENTION_DAYS=90
REQUEST_ANALYTICS_MAX_ROWS=100000
EOF
fi

ui_print ""
ui_print " Install path: $MODPATH"
ui_print " Data path:    $DATA_DIR"
ui_print " Web UI:       http://127.0.0.1:3001"
ui_print " Proxy:        http://127.0.0.1:3001/v1"
ui_print ""
ui_print " Reboot to start the service."
ui_print "=================================="

#!/system/bin/sh
#
# post-fs-data.sh — runs early in boot, before service.sh.
# Just ensures the data directory exists so service.sh can write logs/pid
# without racing against mkdir.

DATA_DIR=/data/local/freellmapi
mkdir -p "$DATA_DIR" "$DATA_DIR/data" "$DATA_DIR/lib" "$DATA_DIR/native"

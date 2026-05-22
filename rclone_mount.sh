#!/bin/bash
REMOTE="ayanomibancho:ayanomibancho-data"
MOUNT_POINT="/mnt/osu_data"

echo "========================================"
echo "  AyanomiBancho - rclone Drive Mount"
echo "========================================"
echo ""
echo "[*] Mounting Google Drive to $MOUNT_POINT"
echo "    Remote: $REMOTE"
echo ""

# Create mount point if it doesn't exist
sudo mkdir -p "$MOUNT_POINT"

rclone mount "$REMOTE" "$MOUNT_POINT" \
    --vfs-cache-mode full \
    --vfs-cache-max-age 1h \
    --vfs-cache-max-size 500M \
    --vfs-read-chunk-size 1M \
    --vfs-read-chunk-size-limit 100M \
    --dir-cache-time 30s \
    --poll-interval 15s \
    --transfers 4 \
    --allow-other \
    --log-level INFO

echo ""
echo "[!] Mount disconnected."

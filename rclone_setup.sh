#!/bin/bash
echo "========================================"
echo "  AyanomiBancho - rclone Google Drive Setup"
echo "========================================"
echo ""

echo "[1] Creating rclone remote 'ayanomibancho'..."
rclone config create ayanomibancho drive

echo ""
echo "[2] Testing connection..."
rclone lsd ayanomibancho: --max-depth 1

echo ""
echo "[3] Creating data directory structure on Google Drive..."
rclone mkdir ayanomibancho:ayanomibancho-data/avatars
rclone mkdir ayanomibancho:ayanomibancho-data/avatars/default
rclone mkdir ayanomibancho:ayanomibancho-data/beatmaps
rclone mkdir ayanomibancho:ayanomibancho-data/replays
rclone mkdir ayanomibancho:ayanomibancho-data/wallpaper
rclone mkdir ayanomibancho:ayanomibancho-data/welcome

echo ""
echo "========================================"
echo "  Setup Complete!"
echo "========================================"
echo ""
echo "Remote name: ayanomibancho"
echo "Remote path: ayanomibancho:ayanomibancho-data/"
echo "Mount point: /mnt/osu_data"

#!/bin/bash
REMOTE="ayanomibancho:ayanomibancho-data"
LOCAL="data"

usage() {
    echo "Usage: ./rclone_sync.sh [push|pull|bisync]"
    echo ""
    echo "  push   - Upload local data/ to Google Drive"
    echo "  pull   - Download Google Drive data to local data/"
    echo "  bisync - Two-way sync (uses --resync on first run)"
    exit 1
}

case "$1" in
    push)
        echo "[*] Pushing local data to Google Drive..."
        echo "    $LOCAL --> $REMOTE"
        rclone sync "$LOCAL" "$REMOTE" \
            --progress --transfers 4 --checkers 8 \
            --exclude "*.db" --exclude "*.sqlite" --exclude ".gitkeep"
        echo "[OK] Push complete!"
        ;;
    pull)
        echo "[*] Pulling data from Google Drive to local..."
        echo "    $REMOTE --> $LOCAL"
        rclone sync "$REMOTE" "$LOCAL" \
            --progress --transfers 4 --checkers 8 \
            --exclude "*.db" --exclude "*.sqlite"
        echo "[OK] Pull complete!"
        ;;
    bisync)
        echo "[*] Bi-directional sync (local <-> Google Drive)..."
        echo "    $LOCAL <--> $REMOTE"
        rclone bisync "$LOCAL" "$REMOTE" \
            --progress --transfers 4 --checkers 8 \
            --exclude "*.db" --exclude "*.sqlite" --resync
        echo "[OK] Bisync complete!"
        ;;
    *)
        usage
        ;;
esac

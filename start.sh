#!/bin/bash
echo "========================================"
echo "  AyanomiBancho - osu! Private Server"
echo "========================================"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Start Caddy only if the binary is present (optional local HTTPS setup)
if [ -f "./caddy" ]; then
    echo "[*] Starting Caddy (HTTPS)..."
    ./caddy run &
    CADDY_PID=$!
    sleep 2
    trap "kill $CADDY_PID 2>/dev/null; echo '[!] Server stopped.'" EXIT
else
    echo "[*] Caddy executable not found. Assuming external reverse proxy (e.g., Nginx)."
    trap "echo '[!] Server stopped.'" EXIT
fi

# Detect luvit executable
if [ -f "./luvit" ]; then
    LUVIT_BIN="./luvit"
elif command -v luvit &> /dev/null; then
    LUVIT_BIN="luvit"
else
    echo "[ERROR] luvit is not installed and no local executable was found."
    echo "Please install luvit: curl -L https://github.com/luvit/lit/raw/master/get-lit.sh | sh"
    exit 1
fi

# Start Luvit (HTTP backend) in foreground
echo "[*] Starting Luvit server (HTTP on port 13380)..."
echo ""
$LUVIT_BIN main.lua

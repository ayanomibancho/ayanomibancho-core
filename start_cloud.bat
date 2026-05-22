@echo off
title AyanomiBancho Server (with rclone sync)
echo ========================================
echo   AyanomiBancho - osu! Private Server
echo   (with Google Drive data sync)
echo ========================================
echo.

:: Pull latest data from Google Drive before starting
echo [*] Pulling latest data from Google Drive...
call rclone_sync.bat pull
echo.

:: Start Caddy (HTTPS reverse proxy) in background
echo [*] Starting Caddy (HTTPS on port 443)...
start "Caddy" /B caddy.exe run 2>&1 | findstr /V "^$"

:: Small delay to let Caddy bind ports
timeout /t 2 /nobreak >nul

:: Start Luvit (HTTP backend) in foreground
echo [*] Starting Luvit server (HTTP on port 13380)...
echo.
luvit.exe main.lua

:: When server stops, push data back to Google Drive
echo.
echo [*] Server stopped. Pushing data to Google Drive...
call rclone_sync.bat push

echo.
echo [!] Sync complete. Press any key to exit...
taskkill /FI "WINDOWTITLE eq Caddy" /F >nul 2>&1
pause

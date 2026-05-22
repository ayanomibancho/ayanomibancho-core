@echo off
title AyanomiBancho Server
echo ========================================
echo   AyanomiBancho - osu! Private Server
echo ========================================
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

:: If Luvit exits, also kill Caddy
echo.
echo [!] Server stopped. Press any key to exit...
taskkill /FI "WINDOWTITLE eq Caddy" /F >nul 2>&1
pause

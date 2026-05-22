@echo off
title AyanomiBancho - rclone Mount
echo ========================================
echo   AyanomiBancho - rclone Drive Mount
echo ========================================
echo.

set REMOTE=ayanomibancho:ayanomibancho-data
set MOUNT_POINT=R:\ayanomibancho-data

echo [*] Mounting Google Drive to %MOUNT_POINT%
echo     Remote: %REMOTE%
echo.
echo NOTE: This window must stay open while mounted.
echo       Press Ctrl+C to unmount.
echo.
echo TIP: Copy config.local.example.lua to config.local.lua and set
echo      paths.data = "R:/ayanomibancho-data"
echo      to make the server read/write directly from Google Drive.
echo.

rclone mount "%REMOTE%" "%MOUNT_POINT%" ^
  --vfs-cache-mode full ^
  --vfs-cache-max-age 1h ^
  --vfs-cache-max-size 500M ^
  --vfs-read-chunk-size 1M ^
  --vfs-read-chunk-size-limit 100M ^
  --dir-cache-time 30s ^
  --poll-interval 15s ^
  --transfers 4 ^
  --log-level INFO

echo.
echo [!] Mount disconnected.
pause

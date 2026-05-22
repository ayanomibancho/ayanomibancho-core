@echo off
title AyanomiBancho - rclone Sync
echo ========================================
echo   AyanomiBancho - rclone Data Sync
echo ========================================
echo.

set REMOTE=ayanomibancho:ayanomibancho-data
set LOCAL=data

if "%1"=="" goto usage
if "%1"=="push" goto push
if "%1"=="pull" goto pull
if "%1"=="bisync" goto bisync
goto usage

:push
echo [*] Pushing local data to Google Drive...
echo     %LOCAL% --^> %REMOTE%
echo.
rclone sync "%LOCAL%" "%REMOTE%" --progress --transfers 4 --checkers 8 --exclude "*.db" --exclude "*.sqlite" --exclude ".gitkeep"
echo.
echo [OK] Push complete!
goto end

:pull
echo [*] Pulling data from Google Drive to local...
echo     %REMOTE% --^> %LOCAL%
echo.
rclone sync "%REMOTE%" "%LOCAL%" --progress --transfers 4 --checkers 8 --exclude "*.db" --exclude "*.sqlite"
echo.
echo [OK] Pull complete!
goto end

:bisync
echo [*] Bi-directional sync (local ^<-^> Google Drive)...
echo     %LOCAL% ^<--^> %REMOTE%
echo.
rclone bisync "%LOCAL%" "%REMOTE%" --progress --transfers 4 --checkers 8 --exclude "*.db" --exclude "*.sqlite" --resync
echo.
echo [OK] Bisync complete!
goto end

:usage
echo Usage: rclone_sync.bat [push^|pull^|bisync]
echo.
echo   push   - Upload local data/ to Google Drive
echo   pull   - Download Google Drive data to local data/
echo   bisync - Two-way sync (use --resync on first run)
echo.

:end
pause

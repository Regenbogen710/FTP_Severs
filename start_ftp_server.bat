@echo off
setlocal

cd /d "%~dp0"

if exist "config.ini" (
  set "CONFIG_FILE=config.ini"
) else if exist "config\ftp_config.ini" (
  set "CONFIG_FILE=config\ftp_config.ini"
) else (
  set "CONFIG_FILE=ftp_config.ini"
)

if not exist "%CONFIG_FILE%" (
  echo Missing config.ini, ftp_config.ini, or config\ftp_config.ini
  pause
  exit /b 1
)

if not exist "scripts\ftp_watchdog.ps1" (
  echo Missing scripts\ftp_watchdog.ps1
  pause
  exit /b 1
)

if not exist ".ftp_runtime" mkdir ".ftp_runtime" >nul 2>nul
if not exist "logs" mkdir "logs" >nul 2>nul
if exist ".ftp_runtime\shutdown.request" del /f /q ".ftp_runtime\shutdown.request" >nul 2>nul
if exist ".ftp_runtime\ftp_server.started" del /f /q ".ftp_runtime\ftp_server.started" >nul 2>nul

echo Starting FTP server with dual watchdogs...
echo Config: %CD%\%CONFIG_FILE%
echo Logs:   %CD%\logs
echo Terminal config: config.bat

start "FTP Watchdog A" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\ftp_watchdog.ps1" -WatchdogName A
start "FTP Watchdog B" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\ftp_watchdog.ps1" -WatchdogName B

echo.
echo Started. Use stop_ftp_server.bat to stop the FTP service and watchdogs.
echo If this is the first run, run install_pyftpdlib.bat before starting.
pause

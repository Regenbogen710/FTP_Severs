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

if not exist "scripts\ensure_environment.ps1" (
  echo Missing scripts\ensure_environment.ps1
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\ensure_environment.ps1" -Mode Ftp
if %ERRORLEVEL% NEQ 0 (
  echo.
  echo Environment setup was canceled or failed. FTP service was not started.
  pause
  exit /b 1
)

if not exist ".ftp_runtime" mkdir ".ftp_runtime" >nul 2>nul
if not exist "logs" mkdir "logs" >nul 2>nul
if exist ".ftp_runtime\shutdown.request" del /f /q ".ftp_runtime\shutdown.request" >nul 2>nul
if exist ".ftp_runtime\ftp_server.started" del /f /q ".ftp_runtime\ftp_server.started" >nul 2>nul

echo Starting FTP server with dual watchdogs...
echo Config: %CD%\%CONFIG_FILE%
echo Logs:
echo   %CD%\logs\watchdog.log
echo   %CD%\logs\ftp_server.out.log
echo   %CD%\logs\ftp_server.err.log
echo Terminal config: config.bat

start "FTP Watchdog A" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\ftp_watchdog.ps1" -WatchdogName A
start "FTP Watchdog B" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\ftp_watchdog.ps1" -WatchdogName B

echo.
echo Started. Use stop_ftp_server.bat to stop the FTP service and watchdogs.
echo.
echo Waiting briefly for startup logs...
timeout /t 2 /nobreak >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$paths = @('logs\watchdog.log','logs\ftp_server.err.log','logs\ftp_server.out.log'); foreach ($path in $paths) { if (Test-Path -LiteralPath $path) { Write-Host ''; Write-Host ('--- ' + $path + ' tail ---'); Get-Content -LiteralPath $path -Tail 20 -Encoding UTF8 } }"
pause

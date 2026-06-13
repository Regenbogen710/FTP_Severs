@echo off
setlocal

cd /d "%~dp0"

for /f "usebackq delims=" %%E in (`powershell -NoProfile -Command "$path = if (Test-Path 'config\ftp_config.ini') { 'config\ftp_config.ini' } else { 'ftp_config.ini' }; $line = Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_ -match '^\s*ENABLE_FRONTEND\s*=' } | Select-Object -First 1; if ($line) { ($line -split '=', 2)[1].Trim().ToLowerInvariant() } else { 'false' }"`) do set "ENABLE_FRONTEND=%%E"

if /i "%ENABLE_FRONTEND%"=="false" (
  echo Frontend is disabled by ftp_config.ini: ENABLE_FRONTEND=false
  echo Set ENABLE_FRONTEND=true to enable the local control panel.
  pause
  exit /b 0
)

if exist "%~dp0bin\control_panel.exe" (
  echo Starting FTP Control Panel...
  echo URL: http://127.0.0.1:8088
  echo.
  "%~dp0bin\control_panel.exe" --host 127.0.0.1 --port 8088
  exit /b %ERRORLEVEL%
)

echo Starting FTP Control Panel...
echo URL: http://127.0.0.1:8088
echo.

py -3 "%~dp0scripts\control_panel.py" --host 127.0.0.1 --port 8088
if %ERRORLEVEL% EQU 0 exit /b 0

python "%~dp0scripts\control_panel.py" --host 127.0.0.1 --port 8088
if %ERRORLEVEL% EQU 0 exit /b 0

echo.
echo Failed to start the control panel. Please make sure Python 3 is installed.
pause

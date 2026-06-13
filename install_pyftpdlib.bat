@echo off
setlocal

cd /d "%~dp0"

if not exist "scripts\ensure_environment.ps1" (
  echo Missing scripts\ensure_environment.ps1
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\ensure_environment.ps1" -Mode Ftp
if %ERRORLEVEL% NEQ 0 (
  echo.
  echo Environment setup was canceled or failed.
  pause
  exit /b 1
)

echo.
echo Environment is ready.
pause

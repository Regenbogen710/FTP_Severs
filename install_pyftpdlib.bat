@echo off
setlocal

cd /d "%~dp0"

if not exist ".ftp_runtime" mkdir ".ftp_runtime" >nul 2>nul
if not exist ".ftp_runtime\packages" mkdir ".ftp_runtime\packages" >nul 2>nul

set "PACKAGE=pyftpdlib"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$path = if (Test-Path 'config\ftp_config.ini') { 'config\ftp_config.ini' } else { 'ftp_config.ini' }; $line = Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_ -match '^\s*PYFTPDLIB_PACKAGE\s*=' } | Select-Object -First 1; if ($line) { ($line -split '=', 2)[1].Trim() } else { 'pyftpdlib' }"`) do set "PACKAGE=%%P"

echo Installing %PACKAGE% into .ftp_runtime\packages ...

py -3 -m pip install --target ".ftp_runtime\packages" "%PACKAGE%"
if %ERRORLEVEL% EQU 0 goto done

python -m pip install --target ".ftp_runtime\packages" "%PACKAGE%"
if %ERRORLEVEL% EQU 0 goto done

echo.
echo Failed to install pyftpdlib. Please make sure Python 3 and pip are installed.
pause
exit /b 1

:done
echo.
echo pyftpdlib installed successfully.
pause

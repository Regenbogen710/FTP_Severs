$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = Split-Path -Parent $ScriptDir
$PidPath = Join-Path $BaseDir ".ftp_runtime\control_panel.pid"

if (-not (Test-Path -LiteralPath $PidPath)) {
  Write-Output "Control panel PID file does not exist. Nothing to stop."
  exit 0
}

$pidText = Get-Content -LiteralPath $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1
$targetPid = 0
if (-not [int]::TryParse($pidText, [ref]$targetPid)) {
  Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
  Write-Output "Invalid PID file removed."
  exit 0
}

$proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
if (-not $proc) {
  Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
  Write-Output "Control panel is not running."
  exit 0
}

$cim = Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue
if ($cim -and $cim.CommandLine -and ($cim.CommandLine -notlike "*control_panel*")) {
  Write-Output "Skipped PID $targetPid because it does not look like the FTP control panel."
  exit 1
}

Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
Write-Output "Control panel stopped."

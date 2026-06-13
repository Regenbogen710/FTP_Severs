$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = Split-Path -Parent $ScriptDir
$RuntimeDir = Join-Path $BaseDir ".ftp_runtime"
$LogDir = Join-Path $BaseDir "logs"
$ShutdownPath = Join-Path $RuntimeDir "shutdown.request"

function Stop-PidFile {
  param(
    [string]$Path,
    [string]$ExpectedCommandText
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }
  $pidText = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1
  $targetPid = 0
  if ([int]::TryParse($pidText, [ref]$targetPid)) {
    $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if ($proc) {
      $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue
      $commandLine = ""
      if ($cim -and $cim.CommandLine) {
        $commandLine = $cim.CommandLine
      }
      if ($ExpectedCommandText -and $commandLine -and ($commandLine -notlike "*$ExpectedCommandText*")) {
        Write-Output "Skipped PID $targetPid from $Path because it does not look like this FTP service."
        return
      }
      Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
      Write-Output "Stopped PID $targetPid from $Path"
    }
  }
  Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $RuntimeDir)) {
  Write-Output "Runtime folder does not exist. Nothing to stop."
  exit 0
}

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
Set-Content -LiteralPath $ShutdownPath -Value ("shutdown requested at {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding UTF8

Stop-PidFile (Join-Path $RuntimeDir "watchdog-A.pid") "ftp_watchdog.ps1"
Stop-PidFile (Join-Path $RuntimeDir "watchdog-B.pid") "ftp_watchdog.ps1"
Start-Sleep -Milliseconds 300
Stop-PidFile (Join-Path $RuntimeDir "ftp_server.pid") "ftp_server"

Remove-Item -LiteralPath (Join-Path $RuntimeDir "ftp_start.lock") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $RuntimeDir "ftp_server.started") -Force -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $LogDir) {
  Add-Content -LiteralPath (Join-Path $LogDir "watchdog.log") -Value ("[{0}] stop script executed" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding UTF8
}

Write-Output "FTP service and watchdogs stopped."

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = Split-Path -Parent $ScriptDir
$BaseDirFull = [System.IO.Path]::GetFullPath($BaseDir).TrimEnd('\', '/')
$RuntimeDir = Join-Path $BaseDir ".ftp_runtime"
$LogDir = Join-Path $BaseDir "logs"
$ShutdownPath = Join-Path $RuntimeDir "shutdown.request"

function Get-ProcessInfo {
  param([int]$TargetPid)
  return Get-CimInstance Win32_Process -Filter "ProcessId = $TargetPid" -ErrorAction SilentlyContinue
}

function Test-ManagedProcess {
  param(
    [object]$ProcessInfo,
    [string[]]$Needles
  )

  if (-not $ProcessInfo) {
    return $false
  }

  $combined = (($ProcessInfo.CommandLine | Out-String) + " " + ($ProcessInfo.ExecutablePath | Out-String)).ToLowerInvariant()
  if (-not $combined.Contains($BaseDirFull.ToLowerInvariant())) {
    return $false
  }

  foreach ($needle in $Needles) {
    if ($combined.Contains($needle.ToLowerInvariant())) {
      return $true
    }
  }
  return $false
}

function Stop-ProcessTree {
  param([int]$TargetPid)

  $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $TargetPid" -ErrorAction SilentlyContinue
  foreach ($child in $children) {
    Stop-ProcessTree ([int]$child.ProcessId)
  }

  $proc = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
  if ($proc) {
    Stop-Process -Id $TargetPid -Force -ErrorAction SilentlyContinue
    Write-Output "Stopped PID $TargetPid"
  }
}

function Stop-PidFile {
  param(
    [string]$Path,
    [string[]]$ExpectedNeedles
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  $pidText = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1
  $targetPid = 0
  if ([int]::TryParse($pidText, [ref]$targetPid)) {
    $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if ($proc) {
      $cim = Get-ProcessInfo $targetPid
      if ($ExpectedNeedles -and -not (Test-ManagedProcess $cim $ExpectedNeedles)) {
        Write-Output "Skipped PID $targetPid from $Path because it does not look like this FTP service."
        return
      }
      Stop-ProcessTree $targetPid
    }
  }

  Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Stop-ManagedProcessesByScan {
  param([string[]]$Needles)

  $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { Test-ManagedProcess $_ $Needles } |
    Sort-Object ProcessId -Descending

  foreach ($processInfo in $processes) {
    Stop-ProcessTree ([int]$processInfo.ProcessId)
  }
}

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
Set-Content -LiteralPath $ShutdownPath -Value ("shutdown requested at {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding UTF8

Stop-PidFile (Join-Path $RuntimeDir "watchdog-A.pid") @("ftp_watchdog.ps1")
Stop-PidFile (Join-Path $RuntimeDir "watchdog-B.pid") @("ftp_watchdog.ps1")
Start-Sleep -Milliseconds 300
Stop-PidFile (Join-Path $RuntimeDir "ftp_server.pid") @("ftp_server.py", "ftp_server.exe")

Stop-ManagedProcessesByScan @("ftp_server.py", "ftp_server.exe")
Stop-ManagedProcessesByScan @("ftp_watchdog.ps1")

Remove-Item -LiteralPath (Join-Path $RuntimeDir "ftp_start.lock") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $RuntimeDir "watchdog_start.lock") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $RuntimeDir "ftp_server.started") -Force -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $LogDir) {
  Add-Content -LiteralPath (Join-Path $LogDir "watchdog.log") -Value ("[{0}] stop script executed" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding UTF8
}

Write-Output "FTP service and watchdogs stopped."

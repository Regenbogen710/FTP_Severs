param(
  [string]$WatchdogName = "A"
)

$ErrorActionPreference = "Stop"

$WatchdogName = $WatchdogName.ToUpperInvariant()
if ($WatchdogName -ne "A" -and $WatchdogName -ne "B") {
  throw "WatchdogName must be A or B."
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = Split-Path -Parent $ScriptDir
$ConfigPath = Join-Path $BaseDir "config\ftp_config.ini"
if (-not (Test-Path -LiteralPath $ConfigPath)) {
  $ConfigPath = Join-Path $BaseDir "ftp_config.ini"
}
$RuntimeDir = Join-Path $BaseDir ".ftp_runtime"
$LogDir = Join-Path $BaseDir "logs"
$PidPath = Join-Path $RuntimeDir "ftp_server.pid"
$LockPath = Join-Path $RuntimeDir "ftp_start.lock"
$WatchdogStartLockPath = Join-Path $RuntimeDir "watchdog_start.lock"
$ShutdownPath = Join-Path $RuntimeDir "shutdown.request"
$ServerStartedPath = Join-Path $RuntimeDir "ftp_server.started"
$PeerWatchdogName = if ($WatchdogName -eq "A") { "B" } else { "A" }
$WatchdogPidPath = Join-Path $RuntimeDir ("watchdog-" + $WatchdogName + ".pid")
$PeerWatchdogPidPath = Join-Path $RuntimeDir ("watchdog-" + $PeerWatchdogName + ".pid")

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Set-Content -LiteralPath $WatchdogPidPath -Value $PID -Encoding ASCII

function Write-Log {
  param([string]$Message)
  $line = "[{0}] [watchdog-{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $WatchdogName, $Message
  Add-Content -LiteralPath (Join-Path $LogDir "watchdog.log") -Value $line -Encoding UTF8
}

function Test-ShutdownRequested {
  return Test-Path -LiteralPath $ShutdownPath
}

function Request-Shutdown {
  param([string]$Reason)

  Set-Content -LiteralPath $ShutdownPath -Value ("shutdown requested at {0}; reason: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Reason) -Encoding UTF8
  Write-Log $Reason
}

function Get-ProcessFromPidFile {
  param(
    [string]$Path,
    [string]$ExpectedCommandText = ""
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $pidText = (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1)
  $targetPid = 0
  if (-not [int]::TryParse($pidText, [ref]$targetPid)) {
    return $null
  }

  $process = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
  if (-not $process) {
    return $null
  }

  if ($ExpectedCommandText) {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue
    if ($cim -and $cim.CommandLine -and ($cim.CommandLine -notlike "*$ExpectedCommandText*")) {
      return $null
    }
  }

  return $process
}

function Get-FtpServerProcessFromPidFile {
  if (-not (Test-Path -LiteralPath $PidPath)) {
    return $null
  }

  $pidText = (Get-Content -LiteralPath $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1)
  $targetPid = 0
  if (-not [int]::TryParse($pidText, [ref]$targetPid)) {
    return $null
  }

  $process = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
  if (-not $process) {
    return $null
  }

  $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue
  if ($cim -and $cim.CommandLine) {
    if ($cim.CommandLine -like "*ftp_server.py*" -or $cim.CommandLine -like "*ftp_server.exe*") {
      return $process
    }
    return $null
  }

  if ($process.ProcessName -like "*ftp_server*") {
    return $process
  }
  return $null
}

function Start-WatchdogProcess {
  param([string]$Name)

  if (Test-ShutdownRequested) {
    return
  }

  $script = Join-Path $ScriptDir "ftp_watchdog.ps1"
  $args = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-WindowStyle",
    "Hidden",
    "-File",
    $script,
    "-WatchdogName",
    $Name
  )

  $process = Start-Process -FilePath "powershell" -ArgumentList $args -PassThru -WindowStyle Hidden
  Write-Log ("Started peer watchdog {0}, pid={1}" -f $Name, $process.Id)
}

function Ensure-PeerWatchdogRunning {
  if (Test-ShutdownRequested) {
    return
  }

  $peer = Get-ProcessFromPidFile $PeerWatchdogPidPath "ftp_watchdog.ps1"
  if ($peer -and -not $peer.HasExited) {
    return
  }

  Start-Sleep -Milliseconds 800
  $peer = Get-ProcessFromPidFile $PeerWatchdogPidPath "ftp_watchdog.ps1"
  if ($peer -and -not $peer.HasExited) {
    return
  }

  $lockStream = $null
  try {
    $lockStream = [System.IO.File]::Open($WatchdogStartLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

    $peer = Get-ProcessFromPidFile $PeerWatchdogPidPath "ftp_watchdog.ps1"
    if ($peer -and -not $peer.HasExited) {
      return
    }

    Start-WatchdogProcess $PeerWatchdogName
  }
  catch [System.IO.IOException] {
    return
  }
  finally {
    if ($lockStream) {
      $lockStream.Close()
    }
  }
}

function Read-Config {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config not found: $ConfigPath"
  }

  $config = @{}
  foreach ($line in Get-Content -LiteralPath $ConfigPath -Encoding UTF8) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#") -or $trimmed.StartsWith(";")) {
      continue
    }
    $parts = $trimmed.Split("=", 2)
    if ($parts.Count -eq 2) {
      $config[$parts[0].Trim()] = $parts[1].Trim()
    }
  }
  return $config
}

function Get-ConfigValue {
  param(
    [hashtable]$Config,
    [string]$Key,
    [string]$Default
  )
  if ($Config.ContainsKey($Key) -and $Config[$Key] -ne "") {
    return $Config[$Key]
  }
  return $Default
}

function Resolve-RootPath {
  param([string]$PathValue)
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $PathValue))
}

function Assert-SafeRootPath {
  param([string]$RootPath)

  $fullPath = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
  $rootOnly = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\', '/')

  if ($fullPath -eq $rootOnly) {
    throw "Refusing to use drive root as FTP_ROOT: $RootPath"
  }

  $windowsDir = [Environment]::GetFolderPath("Windows").TrimEnd('\', '/')
  $systemDriveRoot = [System.IO.Path]::GetPathRoot($windowsDir).TrimEnd('\', '/')
  if (-not $systemDriveRoot -and $env:SystemDrive) {
    $systemDriveRoot = $env:SystemDrive.TrimEnd('\', '/')
  }

  if ($systemDriveRoot -and $rootOnly.Equals($systemDriveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use Windows system drive as FTP_ROOT: $RootPath"
  }

  $systemDir = [Environment]::GetFolderPath("System").TrimEnd('\', '/')
  $userProfile = [Environment]::GetFolderPath("UserProfile").TrimEnd('\', '/')

  foreach ($blocked in @($windowsDir, $systemDir, $userProfile)) {
    if ($blocked -and $fullPath.Equals($blocked, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to use sensitive folder as FTP_ROOT: $RootPath"
    }
  }
}

function Resolve-Permissions {
  param([hashtable]$Config)

  $mode = (Get-ConfigValue $Config "PERMISSION" "readonly").ToLowerInvariant()
  $permissions = switch ($mode) {
    "readonly" { "elr" }
    "upload" { "elaw" }
    "readwrite" { "elrawfmMT" }
    "full" { "elradfmwMT" }
    "custom" {
      $custom = Get-ConfigValue $Config "CUSTOM_PERMISSIONS" ""
      if ($custom -eq "") { throw "PERMISSION=custom requires CUSTOM_PERMISSIONS." }
      $custom
    }
    default { throw "Unknown PERMISSION value: $mode" }
  }

  $allowed = "elradfmwMT"
  foreach ($char in $permissions.ToCharArray()) {
    if ($allowed.IndexOf($char) -lt 0) {
      throw "Invalid FTP permission character: $char"
    }
  }

  $allowAnonymous = (Get-ConfigValue $Config "ALLOW_ANONYMOUS" "true").ToLowerInvariant()
  $allowAnonymousDelete = (Get-ConfigValue $Config "DANGEROUS_ALLOW_ANONYMOUS_DELETE" "false").ToLowerInvariant()
  if ($allowAnonymous -eq "true" -and $allowAnonymousDelete -ne "true") {
    $permissions = $permissions.Replace("d", "")
  }

  return $permissions
}

function Find-Python {
  $candidates = @(
    @{ File = "py"; Args = @("-3") },
    @{ File = "python"; Args = @() },
    @{ File = "python3"; Args = @() }
  )

  foreach ($candidate in $candidates) {
    $cmd = Get-Command $candidate.File -ErrorAction SilentlyContinue
    if ($cmd) {
      return @{
        File = $candidate.File
        PrefixArgs = $candidate.Args
      }
    }
  }
  throw "Python was not found. Install Python 3 or add it to PATH."
}

function Get-PackagedFtpServer {
  $exePath = Join-Path $BaseDir "bin\ftp_server.exe"
  if (Test-Path -LiteralPath $exePath) {
    return $exePath
  }
  return $null
}

function Invoke-Python {
  param(
    [hashtable]$Python,
    [string[]]$Arguments
  )
  & $Python.File @($Python.PrefixArgs + $Arguments)
}

function Ensure-Pyftpdlib {
  param(
    [hashtable]$Python,
    [hashtable]$Config
  )

  $packageDir = Join-Path $RuntimeDir "packages"
  if (Get-PackagedFtpServer) {
    return $packageDir
  }
  New-Item -ItemType Directory -Force -Path $packageDir | Out-Null

  $env:PYTHONPATH = $packageDir
  $check = Invoke-Python $Python @("-c", "import pyftpdlib; print('ok')") 2>$null
  if ($LASTEXITCODE -eq 0 -and $check -match "ok") {
    return $packageDir
  }

  $autoInstall = (Get-ConfigValue $Config "AUTO_INSTALL_PYFTPDLIB" "false").ToLowerInvariant()
  if ($autoInstall -ne "true") {
    throw "pyftpdlib is not installed. Run install_pyftpdlib.bat, or set AUTO_INSTALL_PYFTPDLIB=true temporarily."
  }

  $packageSpec = Get-ConfigValue $Config "PYFTPDLIB_PACKAGE" "pyftpdlib"
  Write-Log "Installing $packageSpec into $packageDir"
  Invoke-Python $Python @("-m", "pip", "install", "--target", $packageDir, $packageSpec) | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install pyftpdlib."
  }
  return $packageDir
}

function Test-PortOpen {
  param([string]$HostName, [int]$Port)
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $result = $client.BeginConnect($HostName, $Port, $null, $null)
    $ok = $result.AsyncWaitHandle.WaitOne(500, $false)
    if ($ok) {
      $client.EndConnect($result)
    }
    $client.Close()
    return $ok
  }
  catch {
    return $false
  }
}

function Get-ServerProcess {
  return Get-FtpServerProcessFromPidFile
}

function Stop-IfFtpManuallyStopped {
  if (-not (Test-Path -LiteralPath $ServerStartedPath)) {
    return
  }

  $proc = Get-ServerProcess
  if ($proc -and -not $proc.HasExited) {
    return
  }

  Request-Shutdown "FTP server process is gone; treating this as a manual FTP shutdown and stopping watchdogs."
  Remove-Item -LiteralPath $WatchdogPidPath -Force -ErrorAction SilentlyContinue
  exit 0
}

function Start-FtpServer {
  param(
    [hashtable]$Python,
    [string]$PackageDir,
    [hashtable]$Config
  )

  $root = Resolve-RootPath (Get-ConfigValue $Config "FTP_ROOT" "ftp-root")
  Assert-SafeRootPath $root
  New-Item -ItemType Directory -Force -Path $root | Out-Null

  $hostValue = Get-ConfigValue $Config "HOST" "127.0.0.1"
  $portValue = Get-ConfigValue $Config "PORT" "21"
  $permissionValue = Resolve-Permissions $Config

  $env:PYTHONPATH = $PackageDir
  $env:FTP_ROOT = $root
  $env:FTP_HOST = $hostValue
  $env:FTP_PORT = $portValue
  $env:FTP_PERMISSIONS = $permissionValue
  $env:FTP_ALLOW_ANONYMOUS = Get-ConfigValue $Config "ALLOW_ANONYMOUS" "true"
  $env:FTP_USERNAME = Get-ConfigValue $Config "USERNAME" "ftp"
  $env:FTP_PASSWORD = Get-ConfigValue $Config "PASSWORD" "change-me-before-use"
  $env:FTP_PASSIVE_PORTS = Get-ConfigValue $Config "PASSIVE_PORTS" "60000-60050"
  $env:FTP_ENCODING = Get-ConfigValue $Config "FTP_ENCODING" "system"

  if ($env:FTP_ALLOW_ANONYMOUS.ToLowerInvariant() -ne "true") {
    if ($env:FTP_PASSWORD -eq "" -or $env:FTP_PASSWORD -eq "ftp" -or $env:FTP_PASSWORD -eq "change-me-before-use") {
      throw "ALLOW_ANONYMOUS=false requires a non-default PASSWORD."
    }
  }

  $serverScript = Join-Path $ScriptDir "ftp_server.py"
  $stdout = Join-Path $LogDir "ftp_server.out.log"
  $stderr = Join-Path $LogDir "ftp_server.err.log"
  $packagedServer = Get-PackagedFtpServer
  if ($packagedServer) {
    $process = Start-Process -FilePath $packagedServer -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  }
  else {
    $args = @($Python.PrefixArgs + @($serverScript))
    $process = Start-Process -FilePath $Python.File -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  }

  Set-Content -LiteralPath $PidPath -Value $process.Id -Encoding ASCII
  Set-Content -LiteralPath $ServerStartedPath -Value ("started pid={0} at {1}" -f $process.Id, (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding UTF8
  Write-Log ("Started FTP server pid={0}, root={1}, port={2}, permissions={3}" -f $process.Id, $root, $portValue, $permissionValue)
}

function Ensure-ServerRunning {
  param(
    [hashtable]$Python,
    [string]$PackageDir,
    [hashtable]$Config
  )

  $hostValue = Get-ConfigValue $Config "HOST" "127.0.0.1"
  $portValue = [int](Get-ConfigValue $Config "PORT" "21")
  $probeHost = "127.0.0.1"
  if ($hostValue -ne "0.0.0.0" -and $hostValue -ne "::") {
    $probeHost = $hostValue
  }

  $proc = Get-ServerProcess
  if ($proc -and -not $proc.HasExited) {
    return
  }

  Stop-IfFtpManuallyStopped

  if (Test-PortOpen $probeHost $portValue) {
    Write-Log "Port $portValue is already open; not starting another server."
    return
  }

  $lockStream = $null
  try {
    $lockStream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

    $proc = Get-ServerProcess
    if ($proc -and -not $proc.HasExited) {
      return
    }
    if (Test-PortOpen $probeHost $portValue) {
      Write-Log "Port $portValue opened while waiting for lock; not starting another server."
      return
    }

    Start-FtpServer $Python $PackageDir $Config
  }
  catch [System.IO.IOException] {
    return
  }
  finally {
    if ($lockStream) {
      $lockStream.Close()
    }
  }
}

Write-Log "Watchdog started."

while ($true) {
  if (Test-ShutdownRequested) {
    Write-Log "Shutdown requested; watchdog exiting."
    Remove-Item -LiteralPath $WatchdogPidPath -Force -ErrorAction SilentlyContinue
    exit 0
  }

  try {
    Stop-IfFtpManuallyStopped
    Ensure-PeerWatchdogRunning
    Stop-IfFtpManuallyStopped
    $config = Read-Config
    $python = $null
    if (-not (Get-PackagedFtpServer)) {
      $python = Find-Python
    }
    $packageDir = Ensure-Pyftpdlib $python $config
    Ensure-ServerRunning $python $packageDir $config
    $interval = [int](Get-ConfigValue $config "WATCHDOG_INTERVAL_SECONDS" "5")
    Start-Sleep -Seconds ([Math]::Max(1, $interval))
  }
  catch {
    if (Test-ShutdownRequested) {
      Write-Log "Shutdown requested after error; watchdog exiting."
      Remove-Item -LiteralPath $WatchdogPidPath -Force -ErrorAction SilentlyContinue
      exit 0
    }
    Write-Log ("ERROR: " + $_.Exception.Message)
    Start-Sleep -Seconds 5
  }
}

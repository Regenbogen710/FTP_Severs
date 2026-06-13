$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = Split-Path -Parent $ScriptDir
$ConfigPath = Join-Path $BaseDir "config.ini"
if (-not (Test-Path -LiteralPath $ConfigPath)) {
  $ConfigPath = Join-Path $BaseDir "config\ftp_config.ini"
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
  $ConfigPath = Join-Path $BaseDir "ftp_config.ini"
}

$ConfigOrder = @(
  "FTP_ROOT",
  "HOST",
  "PORT",
  "PERMISSION",
  "CUSTOM_PERMISSIONS",
  "DANGEROUS_ALLOW_ANONYMOUS_DELETE",
  "ALLOW_ANONYMOUS",
  "USERNAME",
  "PASSWORD",
  "PASSIVE_PORTS",
  "FTP_ENCODING",
  "WATCHDOG_INTERVAL_SECONDS",
  "AUTO_INSTALL_PYFTPDLIB",
  "PYFTPDLIB_PACKAGE",
  "ENABLE_FRONTEND"
)

$Defaults = @{
  FTP_ROOT = "ftp-root"
  HOST = "192.168.110.107"
  PORT = "21"
  PERMISSION = "readonly"
  CUSTOM_PERMISSIONS = ""
  DANGEROUS_ALLOW_ANONYMOUS_DELETE = "false"
  ALLOW_ANONYMOUS = "true"
  USERNAME = "ftp"
  PASSWORD = "change-me-before-use"
  PASSIVE_PORTS = "60000-60050"
  FTP_ENCODING = "system"
  WATCHDOG_INTERVAL_SECONDS = "5"
  AUTO_INSTALL_PYFTPDLIB = "false"
  PYFTPDLIB_PACKAGE = "pyftpdlib"
  ENABLE_FRONTEND = "false"
}

function Read-Config {
  $config = @{}
  foreach ($key in $Defaults.Keys) {
    $config[$key] = $Defaults[$key]
  }

  if (Test-Path -LiteralPath $ConfigPath) {
    foreach ($line in Get-Content -LiteralPath $ConfigPath -Encoding UTF8) {
      $trimmed = $line.Trim()
      if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#") -or $trimmed.StartsWith(";")) {
        continue
      }
      $parts = $trimmed.Split("=", 2)
      if ($parts.Count -eq 2 -and $Defaults.ContainsKey($parts[0].Trim())) {
        $config[$parts[0].Trim()] = $parts[1].Trim()
      }
    }
  }
  return $config
}

function Write-Config {
  param([hashtable]$Config)

  $content = @"
# FTP server config
#
# FTP_ROOT can be absolute, or relative to this folder.
# FTP_ROOT must not be placed on the Windows system drive.
# Examples:
# FTP_ROOT=ftp-root
# FTP_ROOT=D:\FTPShare
FTP_ROOT=$($Config.FTP_ROOT)

# Listen address and port.
# Bind to the lab FTP IP by default.
# Use HOST=0.0.0.0 only when you really want all network interfaces.
HOST=$($Config.HOST)
PORT=$($Config.PORT)

# Permission mode:
# readonly  = list/read only
# upload    = list/upload only, no download/delete
# readwrite = read/write/rename/mkdir, no delete
# full      = all common FTP file permissions
# custom    = use CUSTOM_PERMISSIONS directly
PERMISSION=$($Config.PERMISSION)
CUSTOM_PERMISSIONS=$($Config.CUSTOM_PERMISSIONS)

# Anonymous delete is blocked by default even when PERMISSION=full/custom includes d.
# Set this to true only for short, supervised maintenance windows.
DANGEROUS_ALLOW_ANONYMOUS_DELETE=$($Config.DANGEROUS_ALLOW_ANONYMOUS_DELETE)

# Anonymous access is convenient for lab LAN usage.
# If false, USERNAME and PASSWORD are required.
ALLOW_ANONYMOUS=$($Config.ALLOW_ANONYMOUS)
USERNAME=$($Config.USERNAME)
PASSWORD=$($Config.PASSWORD)

# Passive FTP ports. Open these in firewall if needed.
PASSIVE_PORTS=$($Config.PASSIVE_PORTS)

# FTP command/path encoding.
# system = follow the OS preferred encoding.
# Common values: system, utf-8, gbk, gb2312, big5, cp936
FTP_ENCODING=$($Config.FTP_ENCODING)

# Watchdog behavior.
WATCHDOG_INTERVAL_SECONDS=$($Config.WATCHDOG_INTERVAL_SECONDS)

# If true, hidden watchdogs may install pyftpdlib without asking.
# Default false keeps installation in the visible start/config flow, where the user is asked first.
AUTO_INSTALL_PYFTPDLIB=$($Config.AUTO_INSTALL_PYFTPDLIB)
PYFTPDLIB_PACKAGE=$($Config.PYFTPDLIB_PACKAGE)

# Local web control panel.
# Default is false. Use config.bat for normal configuration.
ENABLE_FRONTEND=$($Config.ENABLE_FRONTEND)
"@

  $configDir = Split-Path -Parent $ConfigPath
  New-Item -ItemType Directory -Force -Path $configDir | Out-Null
  Set-Content -LiteralPath $ConfigPath -Value $content -Encoding UTF8
}

function Assert-NoNewline {
  param([string]$Name, [string]$Value)
  if ($Value -match "[`r`n]") {
    throw "$Name cannot contain newlines."
  }
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
  if ($fullPath.Equals($rootOnly, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "FTP_ROOT cannot be a drive root."
  }

  $windowsDir = [Environment]::GetFolderPath("Windows").TrimEnd('\', '/')
  $systemDriveRoot = [System.IO.Path]::GetPathRoot($windowsDir).TrimEnd('\', '/')
  if (-not $systemDriveRoot -and $env:SystemDrive) {
    $systemDriveRoot = $env:SystemDrive.TrimEnd('\', '/')
  }

  if ($systemDriveRoot -and $rootOnly.Equals($systemDriveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "FTP_ROOT cannot be placed on the Windows system drive."
  }
}

function Normalize-Bool {
  param([string]$Value)
  if ($Value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "y", "on")) {
    return "true"
  }
  return "false"
}

function Validate-Port {
  param([string]$Name, [string]$Value, [int]$Min = 1)
  Assert-NoNewline $Name $Value
  $number = 0
  if (-not [int]::TryParse($Value, [ref]$number)) {
    throw "$Name must be a number."
  }
  if ($number -lt $Min -or $number -gt 65535) {
    throw "$Name must be between $Min and 65535."
  }
  return [string]$number
}

function Validate-PassivePorts {
  param([string]$Value)
  Assert-NoNewline "PASSIVE_PORTS" $Value
  if ($Value.Trim() -eq "") {
    return ""
  }
  if ($Value.Contains("-")) {
    $parts = $Value.Split("-", 2)
    $start = [int](Validate-Port "PASSIVE_PORTS" $parts[0].Trim() 1024)
    $end = [int](Validate-Port "PASSIVE_PORTS" $parts[1].Trim() 1024)
    if ($start -gt $end) {
      throw "PASSIVE_PORTS range start must be <= end."
    }
    if (($end - $start) -gt 500) {
      throw "PASSIVE_PORTS range is too large."
    }
    return "$start-$end"
  }

  $ports = @()
  foreach ($item in $Value.Split(",")) {
    $trimmed = $item.Trim()
    if ($trimmed) {
      $ports += Validate-Port "PASSIVE_PORTS" $trimmed 1024
    }
  }
  if ($ports.Count -gt 100) {
    throw "PASSIVE_PORTS contains too many ports."
  }
  return ($ports -join ",")
}

function Validate-Encoding {
  param([string]$Value)
  Assert-NoNewline "FTP_ENCODING" $Value
  $encoding = $Value.Trim().ToLowerInvariant()
  if ($encoding -eq "" -or $encoding -in @("system", "default", "auto")) {
    return "system"
  }
  if ($encoding -notmatch "^[a-z0-9._-]{1,32}$") {
    throw "FTP_ENCODING contains unsupported characters."
  }
  $allowed = @("utf-8", "utf8", "gbk", "gb2312", "big5", "cp936", "cp950", "latin-1", "ascii")
  if ($encoding -notin $allowed) {
    throw "FTP_ENCODING must be system or a supported value such as utf-8, gbk, gb2312, big5, cp936."
  }
  return $encoding
}

function Validate-Config {
  param([hashtable]$Config)

  foreach ($key in $Config.Keys) {
    Assert-NoNewline $key ([string]$Config[$key])
  }

  $root = Resolve-RootPath $Config.FTP_ROOT
  Assert-SafeRootPath $root

  if ($Config.HOST -ne "localhost") {
    try {
      [System.Net.IPAddress]::Parse($Config.HOST) | Out-Null
    }
    catch {
      throw "HOST must be an IP address or localhost."
    }
  }

  $Config.PORT = Validate-Port "PORT" $Config.PORT

  $permission = $Config.PERMISSION.ToLowerInvariant()
  if ($permission -notin @("readonly", "upload", "readwrite", "full", "custom")) {
    throw "PERMISSION must be readonly, upload, readwrite, full, or custom."
  }
  $Config.PERMISSION = $permission

  foreach ($char in $Config.CUSTOM_PERMISSIONS.ToCharArray()) {
    if ("elradfmwMT".IndexOf($char) -lt 0) {
      throw "CUSTOM_PERMISSIONS contains unsupported permission character: $char"
    }
  }
  if ($Config.PERMISSION -eq "custom" -and $Config.CUSTOM_PERMISSIONS -eq "") {
    throw "CUSTOM_PERMISSIONS is required when PERMISSION=custom."
  }

  $Config.DANGEROUS_ALLOW_ANONYMOUS_DELETE = Normalize-Bool $Config.DANGEROUS_ALLOW_ANONYMOUS_DELETE
  $Config.ALLOW_ANONYMOUS = Normalize-Bool $Config.ALLOW_ANONYMOUS
  $Config.AUTO_INSTALL_PYFTPDLIB = Normalize-Bool $Config.AUTO_INSTALL_PYFTPDLIB
  $Config.ENABLE_FRONTEND = Normalize-Bool $Config.ENABLE_FRONTEND

  if ($Config.USERNAME -notmatch "^[A-Za-z0-9._-]{1,64}$") {
    throw "USERNAME may only contain letters, numbers, dot, underscore, or hyphen."
  }

  if ($Config.PASSWORD.Length -gt 128) {
    throw "PASSWORD is too long."
  }
  if ($Config.ALLOW_ANONYMOUS -ne "true" -and $Config.PASSWORD -in @("", "ftp", "change-me-before-use")) {
    throw "ALLOW_ANONYMOUS=false requires a non-default PASSWORD."
  }

  $Config.PASSIVE_PORTS = Validate-PassivePorts $Config.PASSIVE_PORTS
  $Config.FTP_ENCODING = Validate-Encoding $Config.FTP_ENCODING
  $interval = [int](Validate-Port "WATCHDOG_INTERVAL_SECONDS" $Config.WATCHDOG_INTERVAL_SECONDS)
  if ($interval -gt 3600) {
    throw "WATCHDOG_INTERVAL_SECONDS must be 3600 or less."
  }
  $Config.WATCHDOG_INTERVAL_SECONDS = [string]$interval

  if ($Config.PYFTPDLIB_PACKAGE -notmatch "^[A-Za-z0-9_.-]+([=<>!~]{1,2}[A-Za-z0-9_.-]+)?$") {
    throw "PYFTPDLIB_PACKAGE must be a simple package name or pinned version."
  }

  return $Config
}

function Save-Config {
  param([hashtable]$Config)
  $validated = Validate-Config $Config
  Write-Config $validated
  Write-Host "Saved." -ForegroundColor Green
}

function Show-Config {
  param([hashtable]$Config)
  Clear-Host
  Write-Host "FTP Terminal Config" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "FTP_ROOT: $($Config.FTP_ROOT)"
  Write-Host "HOST: $($Config.HOST)"
  Write-Host "PORT: $($Config.PORT)"
  Write-Host "PERMISSION: $($Config.PERMISSION)"
  Write-Host "ALLOW_ANONYMOUS: $($Config.ALLOW_ANONYMOUS)"
  Write-Host "DANGEROUS_ALLOW_ANONYMOUS_DELETE: $($Config.DANGEROUS_ALLOW_ANONYMOUS_DELETE)"
  Write-Host "PASSIVE_PORTS: $($Config.PASSIVE_PORTS)"
  Write-Host "FTP_ENCODING: $($Config.FTP_ENCODING)"
  Write-Host "WATCHDOG_INTERVAL_SECONDS: $($Config.WATCHDOG_INTERVAL_SECONDS)"
  Write-Host "AUTO_INSTALL_PYFTPDLIB: $($Config.AUTO_INSTALL_PYFTPDLIB)"
  Write-Host "ENABLE_FRONTEND: $($Config.ENABLE_FRONTEND)"
  Write-Host ""
}

function Read-Choice {
  param([string]$Prompt)
  return (Read-Host $Prompt).Trim()
}

function Repair-Environment {
  $ensureScript = Join-Path $ScriptDir "ensure_environment.ps1"
  if (-not (Test-Path -LiteralPath $ensureScript)) {
    throw "Missing scripts\ensure_environment.ps1."
  }

  & powershell -NoProfile -ExecutionPolicy Bypass -File $ensureScript -Mode Ftp
  if ($LASTEXITCODE -ne 0) {
    throw "Environment check failed or was canceled."
  }
}

$config = Read-Config

while ($true) {
  Show-Config $config
  Write-Host "1. Set permission"
  Write-Host "2. Set FTP folder"
  Write-Host "3. Toggle anonymous access"
  Write-Host "4. Toggle anonymous delete"
  Write-Host "5. Set host and port"
  Write-Host "6. Set username/password"
  Write-Host "7. Set FTP encoding"
  Write-Host "8. Toggle frontend"
  Write-Host "9. Check/repair environment"
  Write-Host "10. Save and exit"
  Write-Host "11. Exit without saving"
  Write-Host ""

  $choice = Read-Choice "Choose"
  try {
    switch ($choice) {
      "1" {
        Write-Host "Permission: readonly / upload / readwrite / full / custom"
        $config.PERMISSION = Read-Choice "PERMISSION"
        if ($config.PERMISSION.ToLowerInvariant() -eq "custom") {
          $config.CUSTOM_PERMISSIONS = Read-Choice "CUSTOM_PERMISSIONS"
        }
        Save-Config $config
      }
      "2" {
        $config.FTP_ROOT = Read-Choice "FTP_ROOT"
        Save-Config $config
      }
      "3" {
        $config.ALLOW_ANONYMOUS = if ((Normalize-Bool $config.ALLOW_ANONYMOUS) -eq "true") { "false" } else { "true" }
        Save-Config $config
      }
      "4" {
        $config.DANGEROUS_ALLOW_ANONYMOUS_DELETE = if ((Normalize-Bool $config.DANGEROUS_ALLOW_ANONYMOUS_DELETE) -eq "true") { "false" } else { "true" }
        Save-Config $config
      }
      "5" {
        $config.HOST = Read-Choice "HOST"
        $config.PORT = Read-Choice "PORT"
        Save-Config $config
      }
      "6" {
        $config.USERNAME = Read-Choice "USERNAME"
        $newPassword = Read-Host "PASSWORD"
        if ($newPassword -ne "") {
          $config.PASSWORD = $newPassword
        }
        Save-Config $config
      }
      "7" {
        Write-Host "Encoding examples: system / utf-8 / gbk / gb2312 / big5 / cp936"
        $config.FTP_ENCODING = Read-Choice "FTP_ENCODING"
        Save-Config $config
      }
      "8" {
        $config.ENABLE_FRONTEND = if ((Normalize-Bool $config.ENABLE_FRONTEND) -eq "true") { "false" } else { "true" }
        Save-Config $config
      }
      "9" {
        Repair-Environment
      }
      "10" {
        Save-Config $config
        exit 0
      }
      "11" {
        exit 0
      }
      default {
        Write-Host "Unknown choice." -ForegroundColor Yellow
      }
    }
  }
  catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
  }
  Write-Host ""
  Read-Host "Press Enter to continue" | Out-Null
}

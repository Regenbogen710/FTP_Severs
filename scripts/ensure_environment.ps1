param(
  [ValidateSet("Ftp", "ControlPanel")]
  [string]$Mode = "Ftp",
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = Split-Path -Parent $ScriptDir
$RuntimeDir = Join-Path $BaseDir ".ftp_runtime"
$PackageDir = Join-Path $RuntimeDir "packages"
$ConfigCandidates = @(
  (Join-Path $BaseDir "config.ini"),
  (Join-Path $BaseDir "config\ftp_config.ini"),
  (Join-Path $BaseDir "ftp_config.ini")
)

function Get-ConfigPath {
  foreach ($path in $ConfigCandidates) {
    if (Test-Path -LiteralPath $path) {
      return $path
    }
  }
  return $ConfigCandidates[0]
}

function Read-Config {
  $path = Get-ConfigPath
  $config = @{}
  if (-not (Test-Path -LiteralPath $path)) {
    return $config
  }

  foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
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

function Get-PackagedFtpServer {
  $path = Join-Path $BaseDir "bin\ftp_server.exe"
  if (Test-Path -LiteralPath $path) {
    return $path
  }
  return $null
}

function Get-PackagedControlPanel {
  $path = Join-Path $BaseDir "bin\control_panel.exe"
  if (Test-Path -LiteralPath $path) {
    return $path
  }
  return $null
}

function Invoke-YesNo {
  param([string]$Message)

  if ($CheckOnly) {
    return $false
  }

  Write-Host ""
  Write-Host $Message -ForegroundColor Yellow
  $answer = (Read-Host "Install now? Type Y to continue").Trim().ToLowerInvariant()
  return $answer -in @("y", "yes")
}

function Test-PythonCandidate {
  param([hashtable]$Candidate)
  try {
    $output = & $Candidate.File @($Candidate.PrefixArgs + @("-c", "import sys; print(sys.version_info[0])")) 2>$null
    return ($LASTEXITCODE -eq 0 -and $output -match "3")
  }
  catch {
    return $false
  }
}

function Find-Python {
  $candidates = @(
    @{ File = "py"; PrefixArgs = @("-3") },
    @{ File = "python"; PrefixArgs = @() },
    @{ File = "python3"; PrefixArgs = @() }
  )

  $roots = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Python"),
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)}
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

  foreach ($root in $roots) {
    Get-ChildItem -LiteralPath $root -Directory -Filter "Python*" -ErrorAction SilentlyContinue |
      ForEach-Object {
        $pythonExe = Join-Path $_.FullName "python.exe"
        if (Test-Path -LiteralPath $pythonExe) {
          $candidates += @{ File = $pythonExe; PrefixArgs = @() }
        }
      }
  }

  foreach ($candidate in $candidates) {
    if ($candidate.File -notmatch "^[A-Za-z]:\\" -and -not (Get-Command $candidate.File -ErrorAction SilentlyContinue)) {
      continue
    }
    if (Test-PythonCandidate $candidate) {
      return $candidate
    }
  }
  return $null
}

function Invoke-Python {
  param(
    [hashtable]$Python,
    [string[]]$Arguments
  )
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $Python.File @($Python.PrefixArgs + $Arguments)
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
}

function Install-Python {
  $winget = Get-Command "winget" -ErrorAction SilentlyContinue
  if (-not $winget) {
    throw "Python 3 is missing and winget was not found. Install Python 3 with pip manually, then run start again."
  }

  Write-Host "Installing Python 3 with winget..." -ForegroundColor Cyan
  $baseArgs = @(
    "install",
    "--id", "Python.Python.3.12",
    "--exact",
    "--source", "winget",
    "--accept-package-agreements",
    "--accept-source-agreements"
  )

  & $winget.Source @($baseArgs + @("--scope", "user"))
  if ($LASTEXITCODE -ne 0) {
    & $winget.Source @baseArgs
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Python installation failed."
  }
}

function Ensure-Python {
  $python = Find-Python
  if ($python) {
    return $python
  }

  if (-not (Invoke-YesNo "Python 3 was not found. This program can install Python 3 with winget.")) {
    throw "Python 3 is required but was not installed."
  }

  Install-Python
  $python = Find-Python
  if (-not $python) {
    throw "Python 3 was installed, but it is not visible in this terminal yet. Close this window and start again."
  }
  return $python
}

function Ensure-Pip {
  param([hashtable]$Python)

  Invoke-Python $Python @("-m", "pip", "--version") | Out-Null
  if ($LASTEXITCODE -eq 0) {
    return
  }

  if (-not (Invoke-YesNo "pip was not found for Python 3. This program can repair/install pip with ensurepip.")) {
    throw "pip is required but was not installed."
  }

  Invoke-Python $Python @("-m", "ensurepip", "--upgrade") | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install pip with ensurepip."
  }
}

function Test-Pyftpdlib {
  param([hashtable]$Python)

  New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
  $oldPythonPath = $env:PYTHONPATH
  try {
    $env:PYTHONPATH = $PackageDir
    Invoke-Python $Python @("-c", "import pyftpdlib; print('ok')") 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
  }
  finally {
    $env:PYTHONPATH = $oldPythonPath
  }
}

function Install-Pyftpdlib {
  param(
    [hashtable]$Python,
    [hashtable]$Config
  )

  Ensure-Pip $Python
  New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
  $packageSpec = Get-ConfigValue $Config "PYFTPDLIB_PACKAGE" "pyftpdlib"
  Write-Host "Installing $packageSpec into $PackageDir ..." -ForegroundColor Cyan
  Invoke-Python $Python @("-m", "pip", "install", "--upgrade", "--target", $PackageDir, $packageSpec) | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install $packageSpec."
  }
}

function Ensure-Pyftpdlib {
  param(
    [hashtable]$Python,
    [hashtable]$Config
  )

  if (Test-Pyftpdlib $Python) {
    return
  }

  $autoInstall = (Get-ConfigValue $Config "AUTO_INSTALL_PYFTPDLIB" "false").ToLowerInvariant()
  if ($autoInstall -ne "true") {
    if (-not (Invoke-YesNo "pyftpdlib was not found. This program can install it into .ftp_runtime\packages.")) {
      throw "pyftpdlib is required but was not installed."
    }
  }

  Install-Pyftpdlib $Python $Config
  if (-not (Test-Pyftpdlib $Python)) {
    throw "pyftpdlib was installed, but Python still cannot import it."
  }
}

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
$config = Read-Config

if ($Mode -eq "Ftp" -and (Get-PackagedFtpServer)) {
  Write-Host "Packaged FTP server found; Python is not required." -ForegroundColor Green
  exit 0
}

if ($Mode -eq "ControlPanel" -and (Get-PackagedControlPanel)) {
  Write-Host "Packaged control panel found; Python is not required." -ForegroundColor Green
  exit 0
}

$python = Ensure-Python
Ensure-Pip $python

if ($Mode -eq "Ftp") {
  Ensure-Pyftpdlib $python $config
}

Write-Host "Environment check passed." -ForegroundColor Green

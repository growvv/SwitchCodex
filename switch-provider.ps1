param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$CliArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:CODEX_HOME = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$script:PROFILES_DIR = if ($env:CODEX_PROFILES_DIR) { $env:CODEX_PROFILES_DIR } else { Join-Path $script:CODEX_HOME "config" }
$script:AUTH_FILE = Join-Path $script:CODEX_HOME "auth.json"
$script:CONFIG_FILE = Join-Path $script:CODEX_HOME "config.toml"
$script:BACKUP_ROOT = Join-Path $script:PROFILES_DIR "_backup"
$script:SCRIPT_DIR = Split-Path -Parent $PSCommandPath
$script:MANAGED_BEGIN = "# >>> SwitchCodex >>>"
$script:MANAGED_END = "# <<< SwitchCodex <<<"
$script:ColorEnabled = -not [Console]::IsOutputRedirected -and -not $env:NO_COLOR

function Usage {
  $name = Split-Path -Leaf $PSCommandPath
  @"
Usage:
  $name list
  $name status
  $name save <profile>
  $name import <profile> <auth-file> <config-file>
  $name use <profile>
  $name install [profile-file]
  $name uninstall [profile-file]
  $name <profile>
  $name help

Profile layout:
  $($script:PROFILES_DIR)\<profile>\auth.json
  $($script:PROFILES_DIR)\<profile>\config.toml
"@
}

function Fail([string]$Message) {
  [Console]::Error.WriteLine("Error: $Message")
  exit 1
}

function Write-Colored([string]$Text, [string]$Color, [bool]$NoNewLine = $false) {
  if ($script:ColorEnabled) {
    Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewLine
  } else {
    Write-Host $Text -NoNewline:$NoNewLine
  }
}

function Pad([string]$Text, [int]$Width) {
  $safe = if ($null -eq $Text) { "" } else { $Text }
  if ($safe.Length -ge $Width) { return $safe }
  return $safe.PadRight($Width)
}

function Color-FileState([string]$State) {
  switch ($State) {
    "active" { return "Green" }
    "ready" { return "Green" }
    "missing-auth" { return "Yellow" }
    "missing-config" { return "Yellow" }
    "empty" { return "Red" }
    default { return "DarkGray" }
  }
}

function Color-ProbeState([string]$State) {
  switch ($State) {
    "online" { return "Green" }
    "auth-failed" { return "Yellow" }
    "missing-key" { return "Yellow" }
    "endpoint-mismatch" { return "Yellow" }
    "rate-limited" { return "Yellow" }
    "timeout" { return "Red" }
    "unreachable" { return "Red" }
    "server-error" { return "Red" }
    "no-base-url" { return "Red" }
    "missing-files" { return "Red" }
    default { return "DarkGray" }
  }
}

function Ensure-ProfilesDir {
  if (-not (Test-Path -LiteralPath $script:PROFILES_DIR)) {
    New-Item -ItemType Directory -Path $script:PROFILES_DIR -Force | Out-Null
  }
}

function Validate-ProfileName([string]$Profile) {
  if ([string]::IsNullOrWhiteSpace($Profile)) {
    Fail "Profile name cannot be empty"
  }
  if ($Profile -notmatch "^[A-Za-z0-9._-]+$") {
    Fail "Invalid profile name: $Profile"
  }
  if ($Profile -eq "_backup") {
    Fail "Profile name _backup is reserved"
  }
}

function Profile-Dir([string]$Profile) {
  return Join-Path $script:PROFILES_DIR $Profile
}

function Profile-Auth([string]$Profile) {
  return Join-Path (Profile-Dir $Profile) "auth.json"
}

function Profile-Config([string]$Profile) {
  return Join-Path (Profile-Dir $Profile) "config.toml"
}

function Require-File([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Fail "Missing file: $Path"
  }
}

function Read-Provider([string]$ConfigPath) {
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return "missing"
  }

  foreach ($line in Get-Content -LiteralPath $ConfigPath) {
    if ($line -match '^\s*model_provider\s*=\s*"([^"]+)"') {
      return $Matches[1]
    }
  }
  return "unknown"
}

function Read-TomlStringField([string]$ConfigPath, [string]$Field) {
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return ""
  }

  foreach ($line in Get-Content -LiteralPath $ConfigPath) {
    if ($line -match "^\s*$Field\s*=\s*`"([^`"]*)`"") {
      return $Matches[1]
    }
  }
  return ""
}

function Read-TomlProviderBaseUrl([string]$ConfigPath, [string]$Provider) {
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return ""
  }
  if ([string]::IsNullOrEmpty($Provider)) {
    return ""
  }

  $targetSection = "model_providers.$Provider"
  $inSection = $false
  foreach ($line in Get-Content -LiteralPath $ConfigPath) {
    if ($line -match '^\s*\[([^\]]+)\]\s*$') {
      $inSection = ($Matches[1] -eq $targetSection)
      continue
    }
    if ($inSection -and $line -match '^\s*base_url\s*=\s*"([^"]*)"') {
      return $Matches[1]
    }
  }
  return ""
}

function Read-JsonStringField([string]$JsonPath, [string]$Field) {
  if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) {
    return ""
  }

  try {
    $obj = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
    $val = $obj.$Field
    if ($null -eq $val) { return "" }
    return [string]$val
  } catch {
    return ""
  }
}

function Read-ConnectionFields([string]$ConfigPath, [string]$AuthPath) {
  $provider = Read-Provider $ConfigPath
  if ($provider -eq "missing" -or $provider -eq "unknown") {
    $provider = ""
  }

  return [PSCustomObject]@{
    provider = $provider
    base_url = Read-TomlProviderBaseUrl $ConfigPath $provider
    api_key  = Read-JsonStringField $AuthPath "OPENAI_API_KEY"
  }
}

function Copy-ResolvedFile([string]$SourcePath, [string]$DestinationPath) {
  $resolvedSource = Get-ResolvedPathOrNull $SourcePath
  if ([string]::IsNullOrEmpty($resolvedSource)) {
    $resolvedSource = $SourcePath
  }

  $destinationDir = Split-Path -Parent $DestinationPath
  if (-not [string]::IsNullOrEmpty($destinationDir)) {
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
  }

  [System.IO.File]::Copy($resolvedSource, $DestinationPath, $true)
}

function Probe-ConnectionQuick([string]$BaseUrl, [string]$ApiKey, [double]$ProbeMaxTimeOverride = 0) {
  $probeConnectTimeout = if ($env:SP_PROBE_CONNECT_TIMEOUT) { [double]$env:SP_PROBE_CONNECT_TIMEOUT } else { 0.8 }
  $probeMaxTime = if ($ProbeMaxTimeOverride -gt 0) { $ProbeMaxTimeOverride } elseif ($env:SP_PROBE_MAX_TIME) { [double]$env:SP_PROBE_MAX_TIME } else { 1.8 }
  $connectionTimeoutSec = [Math]::Max(1, [int][Math]::Ceiling($probeConnectTimeout))
  $operationTimeoutSec = [Math]::Max($connectionTimeoutSec, [int][Math]::Ceiling($probeMaxTime))

  $result = [PSCustomObject]@{
    status = "skipped"
    detail = "-"
    latency = "-"
    http_code = "-"
  }

  if ([string]::IsNullOrEmpty($BaseUrl)) {
    $result.status = "no-base-url"
    $result.detail = "base_url missing"
    return $result
  }

  $probeUrl = $BaseUrl.TrimEnd("/") + "/models"
  $headers = @{}
  if (-not [string]::IsNullOrEmpty($ApiKey)) {
    $headers["Authorization"] = "Bearer $ApiKey"
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $resp = Invoke-WebRequest -Uri $probeUrl -Method GET -Headers $headers -ConnectionTimeoutSeconds $connectionTimeoutSec -OperationTimeoutSeconds $operationTimeoutSec -SkipHttpErrorCheck
    $sw.Stop()
    $httpCode = [int]$resp.StatusCode
    $result.http_code = "$httpCode"
    $result.latency = ("{0}ms" -f [int][Math]::Round($sw.Elapsed.TotalMilliseconds))
  } catch {
    $sw.Stop()
    $result.latency = ("{0}ms" -f [int][Math]::Round($sw.Elapsed.TotalMilliseconds))

    $exception = $_.Exception
    $responseProperty = $exception.PSObject.Properties['Response']
    $resp = if ($responseProperty) { $responseProperty.Value } else { $null }
    if ($resp -and $resp.StatusCode) {
      $httpCode = [int]$resp.StatusCode
      $result.http_code = "$httpCode"
    } else {
      $result.http_code = "000"

      if ($exception -is [System.OperationCanceledException] -or $exception.Message -match 'timed out|timeout|canceled') {
        $result.status = "timeout"
        $result.detail = "probe timeout"
      } else {
        $result.status = "unreachable"
        $result.detail = $exception.Message
      }
      return $result
    }
  }

  switch -Regex ($result.http_code) {
    "^[23]\d\d$" {
      $result.status = "online"
      $result.detail = "HTTP $($result.http_code)"
      break
    }
    "^(401|403)$" {
      if ([string]::IsNullOrEmpty($ApiKey)) {
        $result.status = "missing-key"
        $result.detail = "HTTP $($result.http_code) (no key)"
      } else {
        $result.status = "auth-failed"
        $result.detail = "HTTP $($result.http_code)"
      }
      break
    }
    "^404$" {
      $result.status = "endpoint-mismatch"
      $result.detail = "HTTP 404 /models"
      break
    }
    "^429$" {
      $result.status = "rate-limited"
      $result.detail = "HTTP 429"
      break
    }
    "^5\d\d$" {
      $result.status = "server-error"
      $result.detail = "HTTP $($result.http_code)"
      break
    }
    default {
      $result.status = "http-$($result.http_code)"
      $result.detail = "HTTP $($result.http_code)"
      break
    }
  }

  return $result
}

function Get-ResolvedPathOrNull([string]$Path) {
  try {
    return (Resolve-Path -LiteralPath $Path).Path
  } catch {
    return $null
  }
}

function Resolve-SymlinkTarget([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $item = Get-Item -LiteralPath $Path -Force
  if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    return $null
  }

  $target = $item.Target
  if ($target -is [Array]) {
    $target = $target[0]
  }
  if ([string]::IsNullOrEmpty([string]$target)) {
    return $null
  }

  if ([IO.Path]::IsPathRooted($target)) {
    return [string]$target
  }
  return Join-Path (Split-Path -Parent $Path) [string]$target
}

function File-Hash([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ""
  }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Active-Profile {
  $authTarget = Resolve-SymlinkTarget $script:AUTH_FILE
  $configTarget = Resolve-SymlinkTarget $script:CONFIG_FILE
  if ($authTarget -and $configTarget) {
    $authResolved = Get-ResolvedPathOrNull $authTarget
    $configResolved = Get-ResolvedPathOrNull $configTarget
    $authDir = if ($authResolved) { Split-Path -Parent $authResolved } else { $null }
    $configDir = if ($configResolved) { Split-Path -Parent $configResolved } else { $null }
    $profilesRoot = Get-ResolvedPathOrNull $script:PROFILES_DIR
    if ($authDir -and $configDir -and $profilesRoot -and $authDir -eq $configDir -and $authDir.StartsWith($profilesRoot, [StringComparison]::OrdinalIgnoreCase)) {
      return Split-Path -Leaf $authDir
    }
  }

  if (-not (Test-Path -LiteralPath $script:AUTH_FILE -PathType Leaf) -or -not (Test-Path -LiteralPath $script:CONFIG_FILE -PathType Leaf)) {
    return $null
  }

  $authHash = File-Hash $script:AUTH_FILE
  $configHash = File-Hash $script:CONFIG_FILE
  if ([string]::IsNullOrEmpty($authHash) -or [string]::IsNullOrEmpty($configHash)) {
    return $null
  }

  foreach ($dir in (Get-ChildItem -LiteralPath $script:PROFILES_DIR -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "_backup" })) {
    $authPath = Join-Path $dir.FullName "auth.json"
    $configPath = Join-Path $dir.FullName "config.toml"
    if ((File-Hash $authPath) -eq $authHash -and (File-Hash $configPath) -eq $configHash) {
      return $dir.Name
    }
  }

  return $null
}

function Is-Symlink([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $item = Get-Item -LiteralPath $Path -Force
  return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Backup-CurrentTopLevelFiles {
  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $backupDir = Join-Path $script:BACKUP_ROOT $timestamp
  $backedUp = $false

  if ((Test-Path -LiteralPath $script:AUTH_FILE -PathType Leaf) -and -not (Is-Symlink $script:AUTH_FILE)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Copy-Item -LiteralPath $script:AUTH_FILE -Destination (Join-Path $backupDir "auth.json") -Force
    $backedUp = $true
  }

  if ((Test-Path -LiteralPath $script:CONFIG_FILE -PathType Leaf) -and -not (Is-Symlink $script:CONFIG_FILE)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Copy-Item -LiteralPath $script:CONFIG_FILE -Destination (Join-Path $backupDir "config.toml") -Force
    $backedUp = $true
  }

  if ($backedUp) { return $backupDir }
  return ""
}

function Cmd-List {
  Ensure-ProfilesDir
  $currentProfile = Active-Profile

  $rows = @()
  foreach ($dir in (Get-ChildItem -LiteralPath $script:PROFILES_DIR -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "_backup" })) {
    $profile = $dir.Name
    $authPath = Join-Path $dir.FullName "auth.json"
    $configPath = Join-Path $dir.FullName "config.toml"
    $hasAuth = Test-Path -LiteralPath $authPath -PathType Leaf
    $hasConfig = Test-Path -LiteralPath $configPath -PathType Leaf

    $state = "ready"
    if (-not $hasAuth) { $state = "missing-auth" }
    if (-not $hasConfig) { $state = "missing-config" }
    if (-not $hasAuth -and -not $hasConfig) { $state = "empty" }
    if ($profile -eq $currentProfile) { $state = "active" }

    $provider = Read-Provider $configPath
    $probeStatus = "skipped"
    $probeLatency = "-"
    $probeDetail = "-"
    if ($hasAuth -and $hasConfig) {
      $fields = Read-ConnectionFields $configPath $authPath
      $probe = Probe-ConnectionQuick $fields.base_url $fields.api_key 3
      $probeStatus = $probe.status
      $probeLatency = $probe.latency
      $probeDetail = $probe.detail
    }

    $rows += [PSCustomObject]@{
      Profile = $profile
      Provider = $provider
      FileState = $state
      Connect = $probeStatus
      Latency = $probeLatency
      Detail = $probeDetail
    }
  }

  if ($rows.Count -eq 0) {
    Write-Output "(no profiles under $($script:PROFILES_DIR))"
    return
  }

  $rows = $rows | Sort-Object @{ Expression = { if ($_.FileState -eq "active") { 0 } else { 1 } } }, @{ Expression = { $_.Profile } }

  $wProfile = [Math]::Max("PROFILE".Length, ($rows | ForEach-Object { $_.Profile.Length } | Measure-Object -Maximum).Maximum)
  $wProvider = [Math]::Max("PROVIDER".Length, ($rows | ForEach-Object { $_.Provider.Length } | Measure-Object -Maximum).Maximum)
  $wState = [Math]::Max("FILE_STATE".Length, ($rows | ForEach-Object { $_.FileState.Length } | Measure-Object -Maximum).Maximum)
  $wConnect = [Math]::Max("CONNECT".Length, ($rows | ForEach-Object { $_.Connect.Length } | Measure-Object -Maximum).Maximum)
  $wLatency = [Math]::Max("LATENCY".Length, ($rows | ForEach-Object { $_.Latency.Length } | Measure-Object -Maximum).Maximum)

  $header = "{0}  {1}  {2}  {3}  {4}  DETAIL" -f (Pad "PROFILE" $wProfile), (Pad "PROVIDER" $wProvider), (Pad "FILE_STATE" $wState), (Pad "CONNECT" $wConnect), (Pad "LATENCY" $wLatency)
  Write-Colored $header "Cyan"

  foreach ($row in $rows) {
    Write-Host -NoNewline ((Pad $row.Profile $wProfile) + "  " + (Pad $row.Provider $wProvider) + "  ")
    Write-Colored (Pad $row.FileState $wState) (Color-FileState $row.FileState) $true
    Write-Host -NoNewline "  "
    Write-Colored (Pad $row.Connect $wConnect) (Color-ProbeState $row.Connect) $true
    Write-Host -NoNewline "  "
    Write-Colored (Pad $row.Latency $wLatency) "Blue" $true
    Write-Host -NoNewline "  "
    Write-Colored $row.Detail "DarkGray"
  }
}

function Cmd-Status {
  $provider = Read-Provider $script:CONFIG_FILE
  $status = "missing-files"
  $latency = "-"
  if ((Test-Path -LiteralPath $script:CONFIG_FILE -PathType Leaf) -and (Test-Path -LiteralPath $script:AUTH_FILE -PathType Leaf)) {
    $fields = Read-ConnectionFields $script:CONFIG_FILE $script:AUTH_FILE
    $probe = Probe-ConnectionQuick $fields.base_url $fields.api_key
    $status = $probe.status
    $latency = $probe.latency
  }

  Write-Host -NoNewline "status: "
  Write-Colored $status (Color-ProbeState $status)
  Write-Host "latency: $latency"
  Write-Host "provider: $provider"
}

function Cmd-Save([string]$Profile) {
  Validate-ProfileName $Profile
  Ensure-ProfilesDir
  Require-File $script:AUTH_FILE
  Require-File $script:CONFIG_FILE

  $dir = Profile-Dir $Profile
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Copy-ResolvedFile $script:AUTH_FILE (Join-Path $dir "auth.json")
  Copy-ResolvedFile $script:CONFIG_FILE (Join-Path $dir "config.toml")

  Write-Output "Saved current auth/config to profile '$Profile'"
  Write-Output "  $(Join-Path $dir 'auth.json')"
  Write-Output "  $(Join-Path $dir 'config.toml')"
}

function Cmd-Import([string]$Profile, [string]$SourceAuth, [string]$SourceConfig) {
  Validate-ProfileName $Profile
  Ensure-ProfilesDir
  Require-File $SourceAuth
  Require-File $SourceConfig

  $dir = Profile-Dir $Profile
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Copy-ResolvedFile $SourceAuth (Join-Path $dir "auth.json")
  Copy-ResolvedFile $SourceConfig (Join-Path $dir "config.toml")

  Write-Output "Imported profile '$Profile'"
  Write-Output "  auth   <- $SourceAuth"
  Write-Output "  config <- $SourceConfig"
}

function New-SymlinkOrFail([string]$Path, [string]$Target) {
  Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  New-Item -ItemType SymbolicLink -Path $Path -Target $Target -Force | Out-Null
}

function Cmd-Use([string]$Profile) {
  Validate-ProfileName $Profile
  Ensure-ProfilesDir

  $targetAuth = Profile-Auth $Profile
  $targetConfig = Profile-Config $Profile
  Require-File $targetAuth
  Require-File $targetConfig

  $currentProfile = Active-Profile
  if ($currentProfile -eq $Profile) {
    Write-Output "Profile '$Profile' is already active"
    return
  }

  $backupDir = Backup-CurrentTopLevelFiles
  $mode = "symlink"
  try {
    New-SymlinkOrFail $script:AUTH_FILE $targetAuth
    New-SymlinkOrFail $script:CONFIG_FILE $targetConfig
  } catch {
    $mode = "copy"
    Remove-Item -LiteralPath $script:AUTH_FILE -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:CONFIG_FILE -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $targetAuth -Destination $script:AUTH_FILE -Force
    Copy-Item -LiteralPath $targetConfig -Destination $script:CONFIG_FILE -Force
    Write-Host "Symlink not available; switched by copying files." -ForegroundColor Yellow
  }

  Write-Output "Switched to profile '$Profile'"
  if ($mode -eq "symlink") {
    Write-Output "  mode   -> symlink"
    Write-Output "  auth   -> $targetAuth"
    Write-Output "  config -> $targetConfig"
  } else {
    Write-Output "  mode   -> copy"
    Write-Output "  auth   => $($script:AUTH_FILE)"
    Write-Output "  config => $($script:CONFIG_FILE)"
  }
  if (-not [string]::IsNullOrEmpty($backupDir)) {
    Write-Output "Backed up previous top-level files to $backupDir"
  }
}

function Default-PSProfileFile {
  return $PROFILE.CurrentUserCurrentHost
}

function Strip-ManagedLines([string[]]$Lines) {
  $output = New-Object System.Collections.Generic.List[string]
  $skipping = $false
  foreach ($line in $Lines) {
    if ($line -eq $script:MANAGED_BEGIN) {
      $skipping = $true
      continue
    }
    if ($line -eq $script:MANAGED_END) {
      $skipping = $false
      continue
    }
    if (-not $skipping) {
      $output.Add($line)
    }
  }
  return ,$output
}

function PSProfileBlock {
  $escapedScriptDir = $script:SCRIPT_DIR.Replace("'", "''")
  $pathSeparator = [System.IO.Path]::PathSeparator
  return @(
    $script:MANAGED_BEGIN
    "`$env:SWITCH_CODEX_HOME = '$escapedScriptDir'"
    "if (-not ((`$env:Path -split '$pathSeparator') -contains `$env:SWITCH_CODEX_HOME)) {"
    "  `$env:Path = ""`$env:SWITCH_CODEX_HOME$pathSeparator`$env:Path"""
    "}"
    "if (Test-Path Alias:sp) {"
    "  Remove-Item Alias:sp -Force"
    "}"
    "function global:sp {"
    "  & (Join-Path `$env:SWITCH_CODEX_HOME 'switch-provider.ps1') @args"
    "}"
    $script:MANAGED_END
  )
}

function Cmd-Install([string]$ProfileFile = "") {
  $targetProfile = if ([string]::IsNullOrEmpty($ProfileFile)) { Default-PSProfileFile } else { $ProfileFile }
  $profileDir = Split-Path -Parent $targetProfile
  if (-not [string]::IsNullOrEmpty($profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
  }

  $existing = @()
  if (Test-Path -LiteralPath $targetProfile) {
    $existing = Get-Content -LiteralPath $targetProfile
  }
  $cleaned = Strip-ManagedLines $existing
  if ($cleaned.Count -gt 0) {
    $cleaned.Add("")
  }
  foreach ($line in (PSProfileBlock)) {
    $cleaned.Add($line)
  }
  Set-Content -LiteralPath $targetProfile -Value $cleaned -Encoding UTF8

  $hasBegin = Select-String -LiteralPath $targetProfile -SimpleMatch $script:MANAGED_BEGIN -Quiet
  $hasEnd = Select-String -LiteralPath $targetProfile -SimpleMatch $script:MANAGED_END -Quiet
  if (-not ($hasBegin -and $hasEnd)) {
    Write-Colored "Install failed" "Red"
    exit 1
  }

  Write-Colored "Install success" "Green"
  Write-Output "  profile -> $targetProfile"
  Write-Output "  command -> sp"
  Write-Colored "Run: . `"$targetProfile`"" "Cyan"
}

function Cmd-Uninstall([string]$ProfileFile = "") {
  $targetProfile = if ([string]::IsNullOrEmpty($ProfileFile)) { Default-PSProfileFile } else { $ProfileFile }
  if (Test-Path -LiteralPath $targetProfile) {
    $existing = Get-Content -LiteralPath $targetProfile
    $cleaned = Strip-ManagedLines $existing
    Set-Content -LiteralPath $targetProfile -Value $cleaned -Encoding UTF8
  }

  $stillHasBegin = (Test-Path -LiteralPath $targetProfile) -and (Select-String -LiteralPath $targetProfile -SimpleMatch $script:MANAGED_BEGIN -Quiet)
  $stillHasEnd = (Test-Path -LiteralPath $targetProfile) -and (Select-String -LiteralPath $targetProfile -SimpleMatch $script:MANAGED_END -Quiet)
  if ($stillHasBegin -or $stillHasEnd) {
    Write-Colored "Uninstall failed" "Red"
    exit 1
  }

  Write-Colored "Uninstall success" "Green"
  Write-Output "  profile -> $targetProfile"
  Write-Colored "Run: . `"$targetProfile`"" "Cyan"
}

$fallbackArgs = @()
if (Get-Variable -Name args -Scope 0 -ErrorAction SilentlyContinue) {
  $fallbackArgs = $args
}
$rawArgs = if ($null -ne $CliArgs) { $CliArgs } else { $fallbackArgs }
$argList = New-Object System.Collections.Generic.List[string]
foreach ($arg in @($rawArgs)) {
  if ($null -ne $arg) {
    $argList.Add([string]$arg) | Out-Null
  }
}
$argCount = $argList.Count
$command = if ($argCount -gt 0) { $argList[0] } else { "status" }

switch ($command) {
  "help" {
    Usage
  }
  "-h" {
    Usage
  }
  "--help" {
    Usage
  }
  "list" {
    Cmd-List
  }
  "status" {
    Cmd-Status
  }
  "save" {
    if ($argCount -ne 2) { Fail "Usage: $(Split-Path -Leaf $PSCommandPath) save <profile>" }
    Cmd-Save $argList[1]
  }
  "import" {
    if ($argCount -ne 4) { Fail "Usage: $(Split-Path -Leaf $PSCommandPath) import <profile> <auth-file> <config-file>" }
    Cmd-Import $argList[1] $argList[2] $argList[3]
  }
  "use" {
    if ($argCount -ne 2) { Fail "Usage: $(Split-Path -Leaf $PSCommandPath) use <profile>" }
    Cmd-Use $argList[1]
  }
  "install" {
    if ($argCount -gt 2) { Fail "Usage: $(Split-Path -Leaf $PSCommandPath) install [profile-file]" }
    if ($argCount -eq 2) { Cmd-Install $argList[1] } else { Cmd-Install }
  }
  "uninstall" {
    if ($argCount -gt 2) { Fail "Usage: $(Split-Path -Leaf $PSCommandPath) uninstall [profile-file]" }
    if ($argCount -eq 2) { Cmd-Uninstall $argList[1] } else { Cmd-Uninstall }
  }
  "set" {
    Fail "Command 'set' has been removed"
  }
  "unset" {
    Fail "Command 'unset' has been removed"
  }
  default {
    if ($argCount -ne 1) { Fail "Unknown command: $command" }
    Cmd-Use $command
  }
}

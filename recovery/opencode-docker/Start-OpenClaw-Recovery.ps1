[CmdletBinding()]
param(
    [string]$PayloadPath = ".private/pi-recovery.sh",
    [switch]$PreflightOnly,
    [string]$DockerPlatform = "linux/arm64"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Stage([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message"
}

function Add-UniqueCandidate {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $candidate = $Value.Trim()
    if ($candidate -match "[*?]") { return }
    if (-not $List.Contains($candidate)) { $List.Add($candidate) }
}

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path (Join-Path $ScriptDirectory "../..")).Path
Set-Location $ProjectRoot

$ReceiptDirectory = Join-Path $ProjectRoot "receipts"
New-Item -ItemType Directory -Path $ReceiptDirectory -Force | Out-Null
$ReceiptPath = Join-Path $ReceiptDirectory "opencode-windows-pi-recovery.json"
$KnownHostsPath = Join-Path $ReceiptDirectory "opencode-recovery-known-hosts.tmp"

try {
    $PayloadFullPath = (Resolve-Path (Join-Path $ProjectRoot $PayloadPath)).Path
} catch {
    Write-Host "OPENCODE_RECOVERY_BLOCKED reason=payload_missing path=$PayloadPath"
    exit 40
}

$PayloadInfo = Get-Item -LiteralPath $PayloadFullPath
$PayloadSha256 = (Get-FileHash -LiteralPath $PayloadFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
$PayloadBytes = $PayloadInfo.Length
$ManifestPath = Join-Path (Split-Path -Parent $PayloadFullPath) "pi-recovery.manifest.json"

Write-Stage "Payload integrity and syntax preflight"

if (Test-Path -LiteralPath $ManifestPath) {
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Manifest.sha256 -and ([string]$Manifest.sha256).ToLowerInvariant() -ne $PayloadSha256) {
        throw "payload_sha256_mismatch"
    }
    if ($Manifest.bytes -and [int64]$Manifest.bytes -ne $PayloadBytes) {
        throw "payload_byte_count_mismatch"
    }
}

$DockerState = "unavailable"
$SyntaxState = "not_checked"
$DockerCommand = Get-Command docker -ErrorAction SilentlyContinue
$BashCommand = $null
$BashPaths = [System.Collections.Generic.List[string]]::new()
if ($env:ProgramFiles) {
    $BashPaths.Add((Join-Path $env:ProgramFiles "Git/bin/bash.exe"))
    $BashPaths.Add((Join-Path $env:ProgramFiles "Git/usr/bin/bash.exe"))
}
if (${env:ProgramFiles(x86)}) {
    $BashPaths.Add((Join-Path ${env:ProgramFiles(x86)} "Git/bin/bash.exe"))
}
foreach ($BashPath in $BashPaths) {
    if (Test-Path -LiteralPath $BashPath) {
        $BashCommand = Get-Item -LiteralPath $BashPath
        break
    }
}
if (-not $BashCommand) { $BashCommand = Get-Command bash -ErrorAction SilentlyContinue }

if ($DockerCommand) {
    try {
        $null = & $DockerCommand.Source version --format "{{.Server.Version}}" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $PayloadDirectory = Split-Path -Parent $PayloadFullPath
            $PayloadLeaf = Split-Path -Leaf $PayloadFullPath
            $Mount = "type=bind,source=$PayloadDirectory,target=/payload,readonly"
            & $DockerCommand.Source run --rm --platform $DockerPlatform --mount $Mount `
                debian:bookworm-slim bash -n "/payload/$PayloadLeaf"
            if ($LASTEXITCODE -eq 0) {
                $DockerState = "pass"
                $SyntaxState = "pass"
            } else {
                $DockerState = "failed"
            }
        }
    } catch {
        $DockerState = "failed"
    }
}

if ($SyntaxState -ne "pass" -and $BashCommand) {
    & $BashCommand.Source -n $PayloadFullPath
    if ($LASTEXITCODE -eq 0) {
        $SyntaxState = "pass"
        if ($DockerState -eq "failed") { $DockerState = "failed_local_bash_passed" }
    }
}

if ($SyntaxState -ne "pass") {
    throw "no_successful_bash_syntax_preflight"
}

if ($PreflightOnly) {
    [ordered]@{
        result = "preflight_pass"
        payload_sha256 = $PayloadSha256
        payload_bytes = $PayloadBytes
        docker_preflight = $DockerState
        syntax = $SyntaxState
        remote_execution_attempted = $false
        secret_values_included = $false
        completed_at = [DateTimeOffset]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8

    Write-Host "OPENCODE_PREFLIGHT_PASS docker=$DockerState sha256=$PayloadSha256"
    exit 0
}

Write-Stage "Discovering existing Windows SSH and Tailscale routes"

$SshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
if (-not $SshCommand) { $SshCommand = Get-Command ssh -ErrorAction SilentlyContinue }
if (-not $SshCommand) {
    Write-Host "OPENCODE_RECOVERY_BLOCKED reason=windows_ssh_missing"
    exit 41
}

$Candidates = [System.Collections.Generic.List[string]]::new()
foreach ($Known in @(
    "raspberry5",
    "raspberry5.local",
    "raspberrypi",
    "raspberrypi.local",
    "192.168.0.47",
    "100.96.41.125"
)) {
    Add-UniqueCandidate -List $Candidates -Value $Known
}

$SshConfigPath = Join-Path $HOME ".ssh/config"
if (Test-Path -LiteralPath $SshConfigPath) {
    $CurrentAliases = @()
    foreach ($RawLine in Get-Content -LiteralPath $SshConfigPath -ErrorAction SilentlyContinue) {
        $Line = $RawLine.Trim()
        if ($Line -match "(?i)^Host\s+(.+)$") {
            $CurrentAliases = $Matches[1] -split "\s+"
            foreach ($Alias in $CurrentAliases) {
                if ($Alias -match "(?i)raspberry|openclaw|odi|pi5") {
                    Add-UniqueCandidate -List $Candidates -Value $Alias
                }
            }
            continue
        }
        if ($Line -match "(?i)^HostName\s+(.+)$") {
            $HostName = $Matches[1].Trim()
            if ($HostName -match "(?i)raspberry|openclaw|odi|pi5|^192\.168\.0\.47$|^100\.96\.41\.125$") {
                foreach ($Alias in $CurrentAliases) {
                    Add-UniqueCandidate -List $Candidates -Value $Alias
                }
                Add-UniqueCandidate -List $Candidates -Value $HostName
            }
        }
    }
}

$TailscaleCommand = Get-Command tailscale.exe -ErrorAction SilentlyContinue
if (-not $TailscaleCommand) { $TailscaleCommand = Get-Command tailscale -ErrorAction SilentlyContinue }
if ($TailscaleCommand) {
    try {
        $StatusRaw = & $TailscaleCommand.Source status --json 2>$null
        if ($LASTEXITCODE -eq 0 -and $StatusRaw) {
            $Status = $StatusRaw | ConvertFrom-Json
            if ($Status.Peer) {
              foreach ($Property in $Status.Peer.PSObject.Properties) {
                $Peer = $Property.Value
                $Names = @($Peer.HostName, $Peer.DNSName) | Where-Object { $_ }
                if (($Names -join " ") -match "(?i)raspberry|openclaw|odi|pi5") {
                    foreach ($Name in $Names) { Add-UniqueCandidate -List $Candidates -Value ([string]$Name) }
                    foreach ($Address in @($Peer.TailscaleIPs)) {
                        Add-UniqueCandidate -List $Candidates -Value ([string]$Address)
                    }
                }
              }
            }
        }
    } catch {
        # Read-only discovery is optional.
    }
}

$CommonSshArgs = @(
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=7",
    "-o", "ConnectionAttempts=1",
    "-o", "ServerAliveInterval=10",
    "-o", "ServerAliveCountMax=2",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=$KnownHostsPath"
)

$Probe = @'
set -eu
MODEL="$(tr -d '\000' </proc/device-tree/model 2>/dev/null || true)"
if printf '%s' "$MODEL" | grep -q 'Raspberry Pi 5' \
  && test -f "$HOME/.openclaw/openclaw.json" \
  && command -v openclaw >/dev/null 2>&1; then
  printf 'ODI_PI5_OK|%s|%s|%s\n' "$MODEL" "$(hostname)" "$(id -un)"
  exit 0
fi
exit 42
'@

$Target = $null
$ProbeEvidence = $null
$Attempted = [System.Collections.Generic.List[string]]::new()
$RawUsers = @("", "mnwersdfppap", "pi", "ubuntu")

foreach ($Candidate in $Candidates) {
    foreach ($User in $RawUsers) {
        $Login = if ([string]::IsNullOrWhiteSpace($User)) { $Candidate } else { "$User@$Candidate" }
        if ($Attempted.Contains($Login)) { continue }
        $Attempted.Add($Login)

        $Output = & $SshCommand.Source @CommonSshArgs $Login $Probe 2>$null
        $ExitCode = $LASTEXITCODE
        if ($ExitCode -eq 0 -and (($Output -join "`n") -match "^ODI_PI5_OK\|")) {
            $Target = $Login
            $ProbeEvidence = ($Output -join "`n").Trim()
            break
        }
    }
    if ($Target) { break }
}

if (-not $Target) {
    [ordered]@{
        result = "blocked"
        blocker = "no_authenticated_attested_pi5_ssh_target"
        candidates_considered = $Candidates.Count
        logins_attempted = $Attempted.Count
        password_auth_attempted = $false
        docker_preflight = $DockerState
        payload_sha256 = $PayloadSha256
        payload_bytes = $PayloadBytes
        secret_values_included = $false
        completed_at = [DateTimeOffset]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8

    Remove-Item -LiteralPath $KnownHostsPath -Force -ErrorAction SilentlyContinue
    Write-Host "OPENCODE_RECOVERY_BLOCKED reason=no_authenticated_attested_pi5_ssh_target receipt=$ReceiptPath"
    exit 42
}

Write-Stage "Executing the verified payload exactly once on the attested Raspberry Pi 5"

$PayloadText = [System.IO.File]::ReadAllText($PayloadFullPath, [System.Text.UTF8Encoding]::new($false))
$PayloadText | & $SshCommand.Source @CommonSshArgs $Target "bash -s"
$PayloadExitCode = $LASTEXITCODE

$VerifyCommand = @'
set -u
GATEWAY="$(systemctl --user is-active openclaw-gateway.service 2>/dev/null || true)"
RPC=false
if openclaw gateway status --require-rpc >/dev/null 2>&1; then RPC=true; fi
RECEIPT=false
if test -s "$HOME/.openclaw/receipts/full-recovery-dispatcher-20260821.json" \
   || test -s "$HOME/.openclaw/receipts/pi-auth-repair-20260821.json"; then RECEIPT=true; fi
printf 'ODI_VERIFY|gateway=%s|rpc=%s|receipt=%s\n' "$GATEWAY" "$RPC" "$RECEIPT"
'@

$Verification = & $SshCommand.Source @CommonSshArgs $Target $VerifyCommand 2>$null
$VerificationText = ($Verification -join "`n").Trim()
$Ready = $PayloadExitCode -eq 0 -and $VerificationText -match "rpc=true"

[ordered]@{
    result = if ($Ready) { "ready" } else { "partial" }
    target = $Target
    target_attestation = $ProbeEvidence
    payload_exit_code = $PayloadExitCode
    verification = $VerificationText
    payload_sha256 = $PayloadSha256
    payload_bytes = $PayloadBytes
    docker_preflight = $DockerState
    password_auth_attempted = $false
    tailscale_state_changed = $false
    reboot_performed = $false
    secret_values_included = $false
    completed_at = [DateTimeOffset]::UtcNow.ToString("o")
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8

Remove-Item -LiteralPath $KnownHostsPath -Force -ErrorAction SilentlyContinue

if ($Ready) {
    Write-Host "OPENCODE_RECOVERY_READY target=$Target receipt=$ReceiptPath"
    exit 0
}

Write-Host "OPENCODE_RECOVERY_PARTIAL target=$Target payload_exit=$PayloadExitCode receipt=$ReceiptPath"
exit 43

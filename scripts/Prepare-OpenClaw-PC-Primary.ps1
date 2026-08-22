[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path $env:USERPROFILE '.openclaw'
$receiptDir = Join-Path $root 'receipts'
$receiptPath = Join-Path $receiptDir 'pc-primary-preflight-v1.json'
New-Item -ItemType Directory -Force -Path $receiptDir | Out-Null

# PC-primary safety contract: n8n remains the sole operational scheduler.
# OpenClaw native cron is disabled. This script creates no Telegram poller,
# performs no host reboot, and does not touch Raspberry Pi data/volumes.
[Environment]::SetEnvironmentVariable('OPENCLAW_SKIP_CRON', '1', 'User')
$env:OPENCLAW_SKIP_CRON = '1'

$installedNow = $false
if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
    $installer = Invoke-WebRequest -UseBasicParsing 'https://openclaw.ai/install.ps1'
    & ([scriptblock]::Create($installer.Content)) -NoOnboard
    $installedNow = $true
}

if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
    throw 'OPENCLAW_CLI_NOT_AVAILABLE_AFTER_INSTALL'
}

$version = (& openclaw --version 2>&1 | Out-String).Trim()
$doctorExit = $null
try {
    & openclaw doctor *> (Join-Path $receiptDir 'pc-primary-doctor-v1.txt')
    $doctorExit = $LASTEXITCODE
} catch {
    $doctorExit = 1
}

$gatewayStatusExit = $null
try {
    & openclaw gateway status --json *> (Join-Path $receiptDir 'pc-primary-gateway-status-v1.json')
    $gatewayStatusExit = $LASTEXITCODE
} catch {
    $gatewayStatusExit = 1
}

$skipCron = [Environment]::GetEnvironmentVariable('OPENCLAW_SKIP_CRON','User')
if ($skipCron -ne '1') { throw 'OPENCLAW_SKIP_CRON_NOT_PERSISTED' }

$receipt = [ordered]@{
    completed_at = [DateTimeOffset]::UtcNow.ToString('o')
    result = 'pc_primary_preflight_complete'
    contract_version = 1
    openclaw_cli_present = $true
    openclaw_installed_now = $installedNow
    openclaw_version = $version
    doctor_exit_code = $doctorExit
    gateway_status_exit_code = $gatewayStatusExit
    openclaw_native_cron_disabled = $true
    n8n_sole_operational_scheduler_required = $true
    gateway_service_install_performed = $false
    telegram_poller_created = $false
    raspberry_pi_mutated = $false
    docker_volumes_deleted = $false
    host_rebooted = $false
    permissions_expanded = $false
    secret_values_included = $false
    next_state = 'ready_for_existing_config_handoff_and_gateway_activation_after_validation'
}
$receipt | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $receiptPath

Write-Output "PC_PRIMARY_PREFLIGHT_OK receipt=$receiptPath version=$version"

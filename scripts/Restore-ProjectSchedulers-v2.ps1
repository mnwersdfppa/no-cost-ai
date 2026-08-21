[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Join-Path $env:USERPROFILE ".openclaw"
$backupRoot = Join-Path $root "backups"
$latestPointer = Join-Path $backupRoot "windows-schedulers-latest.txt"
$receiptDir = Join-Path $root "receipts"
$receiptPath = Join-Path $receiptDir "windows-schedulers-restored-v2.json"

$backup = $null
if (Test-Path $latestPointer -PathType Leaf) {
    $candidate = (Get-Content -Raw $latestPointer).Trim()
    if ($candidate -and (Test-Path $candidate -PathType Container)) {
        $backup = $candidate
    }
}
if (-not $backup) {
    $latest = Get-ChildItem $backupRoot -Directory -Filter "windows-schedulers-*" |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($latest) { $backup = $latest.FullName }
}
if (-not $backup) {
    Write-Output "WINDOWS_SCHEDULER_ROLLBACK_BLOCKED reason=backup_not_found"
    exit 40
}

$statePath = Join-Path $backup "state.before.json"
if (-not (Test-Path $statePath -PathType Leaf)) {
    Write-Output "WINDOWS_SCHEDULER_ROLLBACK_BLOCKED reason=state_manifest_missing"
    exit 41
}
$before = Get-Content -Raw $statePath | ConvertFrom-Json

foreach ($task in @($before.tasks)) {
    if ($task.Enabled -eq $true) {
        Enable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath |
            Out-Null
    }
}

if ($before.previous_openclaw_skip_cron_user_value_present -eq $true) {
    [Environment]::SetEnvironmentVariable(
        "OPENCLAW_SKIP_CRON",
        [string]$before.previous_openclaw_skip_cron_user_value,
        "User"
    )
    $env:OPENCLAW_SKIP_CRON = [string]$before.previous_openclaw_skip_cron_user_value
} else {
    [Environment]::SetEnvironmentVariable("OPENCLAW_SKIP_CRON", $null, "User")
    Remove-Item Env:OPENCLAW_SKIP_CRON -ErrorAction SilentlyContinue
}

$gatewayRestartAttempted = $false
$gatewayRestartSucceeded = $false
if ($before.gateway_cli_present -eq $true -and $before.gateway_was_healthy -eq $true) {
    $gatewayRestartAttempted = $true
    & openclaw gateway restart *> (Join-Path $backup "gateway-rollback-restart.txt")
    if ($LASTEXITCODE -eq 0) {
        Start-Sleep -Seconds 3
        & openclaw gateway status *> (Join-Path $backup "gateway-rollback-status.txt")
        $gatewayRestartSucceeded = $LASTEXITCODE -eq 0
    }
    if (-not $gatewayRestartSucceeded) {
        throw "OPENCLAW_GATEWAY_ROLLBACK_RESTART_FAILED"
    }
}

New-Item -ItemType Directory -Force -Path $receiptDir | Out-Null
$receipt = [ordered]@{
    completed_at = [DateTimeOffset]::UtcNow.ToString("o")
    result = "project_windows_schedulers_restored"
    contract_version = 2
    backup_path = $backup
    openclaw_native_cron_kill_switch_removed_or_restored = $true
    task_count_considered = @($before.tasks).Count
    gateway_restart_attempted = $gatewayRestartAttempted
    gateway_restart_succeeded = $gatewayRestartSucceeded
    automatic_host_reboot = $false
    unknown_process_kill = $false
    secret_values_included = $false
}
$receipt | ConvertTo-Json -Depth 8 |
    Set-Content -Encoding UTF8 -Path $receiptPath

Write-Output "WINDOWS_SCHEDULERS_RESTORED native_cron=restored receipt=$receiptPath backup=$backup"

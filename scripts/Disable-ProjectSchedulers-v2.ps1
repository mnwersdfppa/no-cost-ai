[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Join-Path $env:USERPROFILE ".openclaw"
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$backupRoot = Join-Path $root "backups"
$backup = Join-Path $backupRoot "windows-schedulers-$stamp"
$receiptDir = Join-Path $root "receipts"
$receiptPath = Join-Path $receiptDir "windows-schedulers-disabled-v2.json"
$latestPointer = Join-Path $backupRoot "windows-schedulers-latest.txt"

New-Item -ItemType Directory -Force -Path $backupRoot, $backup, $receiptDir | Out-Null

$projectPatterns = @(
    "OpenClaw",
    "ODI",
    "n8n",
    "LangGraph",
    "LangChain",
    "LangSmith"
)
$controlPatterns = @(
    "Recovery",
    "Session Refresh",
    "Telegram Delivery",
    "External Scheduler Actuator",
    "Gateway",
    "Tailscale"
)

function MatchesAny([string]$Value, [string[]]$Patterns) {
    foreach ($pattern in $Patterns) {
        if ($Value -match [regex]::Escape($pattern)) { return $true }
    }
    return $false
}

$tasks = @(Get-ScheduledTask | Where-Object {
    $label = "$($_.TaskPath)$($_.TaskName)"
    (MatchesAny $label $projectPatterns) -and
    -not (MatchesAny $label $controlPatterns)
})

$manifestTasks = @()
foreach ($task in $tasks) {
    $xmlFile = Join-Path $backup ("task-" + [Guid]::NewGuid().ToString("N") + ".xml")
    try {
        Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath |
            Set-Content -Encoding Unicode -Path $xmlFile
    } catch {
        $xmlFile = $null
    }
    $manifestTasks += [ordered]@{
        TaskName = $task.TaskName
        TaskPath = $task.TaskPath
        State = [string]$task.State
        Enabled = [bool]$task.Settings.Enabled
        XmlFile = $xmlFile
    }
}

$previousUserValue = [Environment]::GetEnvironmentVariable(
    "OPENCLAW_SKIP_CRON",
    "User"
)
$gatewayCliPresent = $null -ne (Get-Command openclaw -ErrorAction SilentlyContinue)
$gatewayWasHealthy = $false
if ($gatewayCliPresent) {
    & openclaw gateway status *> (Join-Path $backup "gateway-status.before.txt")
    $gatewayWasHealthy = $LASTEXITCODE -eq 0
}

$before = [ordered]@{
    captured_at = [DateTimeOffset]::UtcNow.ToString("o")
    tasks = $manifestTasks
    previous_openclaw_skip_cron_user_value = $previousUserValue
    previous_openclaw_skip_cron_user_value_present = $null -ne $previousUserValue
    gateway_cli_present = $gatewayCliPresent
    gateway_was_healthy = $gatewayWasHealthy
    secret_values_included = $false
}
$before | ConvertTo-Json -Depth 8 |
    Set-Content -Encoding UTF8 (Join-Path $backup "state.before.json")

foreach ($task in $tasks) {
    Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath |
        Out-Null
}

# OpenClaw current jobs are persisted in its own scheduler store. Apply the
# official global kill switch without deleting job definitions.
[Environment]::SetEnvironmentVariable("OPENCLAW_SKIP_CRON", "1", "User")
$env:OPENCLAW_SKIP_CRON = "1"

$gatewayRestartAttempted = $false
$gatewayRestartSucceeded = $false
if ($gatewayCliPresent -and $gatewayWasHealthy) {
    $gatewayRestartAttempted = $true
    & openclaw gateway restart *> (Join-Path $backup "gateway-restart.txt")
    if ($LASTEXITCODE -eq 0) {
        Start-Sleep -Seconds 3
        & openclaw gateway status *> (Join-Path $backup "gateway-status.after.txt")
        $gatewayRestartSucceeded = $LASTEXITCODE -eq 0
    }
    if (-not $gatewayRestartSucceeded) {
        throw "OPENCLAW_GATEWAY_RESTART_FAILED"
    }
}

$verifiedUserValue = [Environment]::GetEnvironmentVariable(
    "OPENCLAW_SKIP_CRON",
    "User"
)
if ($verifiedUserValue -ne "1") {
    throw "OPENCLAW_SKIP_CRON_USER_ENV_NOT_SET"
}

Set-Content -Encoding UTF8 -Path $latestPointer -Value $backup

$receipt = [ordered]@{
    completed_at = [DateTimeOffset]::UtcNow.ToString("o")
    result = "project_windows_schedulers_disabled"
    contract_version = 2
    scope = "project_scheduled_tasks_and_openclaw_native_cron"
    backup_path = $backup
    disabled_task_count = $tasks.Count
    openclaw_native_cron_kill_switch = $true
    openclaw_skip_cron_user_environment_set = $true
    job_definitions_deleted = $false
    gateway_restart_attempted = $gatewayRestartAttempted
    gateway_restart_succeeded = $gatewayRestartSucceeded
    rollback_script = "Restore-ProjectSchedulers-v2.ps1"
    rollback_ready = $true
    automatic_host_reboot = $false
    unknown_process_kill = $false
    secret_values_included = $false
}
$receipt | ConvertTo-Json -Depth 8 |
    Set-Content -Encoding UTF8 -Path $receiptPath

Write-Output "WINDOWS_SCHEDULERS_DISABLED native_cron=off receipt=$receiptPath backup=$backup"

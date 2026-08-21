[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = "Stop"
$root = Join-Path $env:USERPROFILE ".openclaw"
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$backup = Join-Path $root "backups\windows-tasks-$stamp"
$receiptDir = Join-Path $root "receipts"
New-Item -ItemType Directory -Force -Path $backup, $receiptDir | Out-Null

$patterns = @("OpenClaw", "ODI", "n8n", "LangGraph")
$tasks = Get-ScheduledTask | Where-Object {
    $name = "$($_.TaskPath)$($_.TaskName)"
    ($patterns | Where-Object { $name -match [regex]::Escape($_) }).Count -gt 0
}

$export = foreach ($task in $tasks) {
    [pscustomobject]@{
        TaskName = $task.TaskName
        TaskPath = $task.TaskPath
        State = [string]$task.State
        Enabled = [bool]$task.Settings.Enabled
    }
}
$export | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $backup "tasks.before.json")

foreach ($task in $tasks) {
    $label = "$($task.TaskPath)$($task.TaskName)"
    if ($PSCmdlet.ShouldProcess($label, "Disable scheduled task")) {
        Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-Null
    }
}

$receipt = [ordered]@{
    completed_at = (Get-Date).ToUniversalTime().ToString("o")
    result = "project_windows_tasks_disabled"
    scope = "project_schedulers_only"
    backup_path = $backup
    disabled_task_count = $tasks.Count
    automatic_reboot = $false
    unknown_process_kill = $false
    secret_values_included = $false
}
$receipt | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $receiptDir "windows-tasks-disabled.json")
Write-Output "WINDOWS_PROJECT_TASKS_DISABLED receipt=$receiptDir\windows-tasks-disabled.json backup=$backup"

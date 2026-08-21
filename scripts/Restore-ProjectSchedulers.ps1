[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = "Stop"
$root = Join-Path $env:USERPROFILE ".openclaw"
$latest = Get-ChildItem (Join-Path $root "backups") -Directory -Filter "windows-tasks-*" |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1

if (-not $latest) {
    Write-Output "WINDOWS_TASK_ROLLBACK_BLOCKED reason=backup_not_found"
    exit 40
}

$file = Join-Path $latest.FullName "tasks.before.json"
if (-not (Test-Path $file)) {
    Write-Output "WINDOWS_TASK_ROLLBACK_BLOCKED reason=manifest_not_found"
    exit 41
}

$tasks = Get-Content -Raw $file | ConvertFrom-Json
foreach ($task in @($tasks)) {
    if ($task.Enabled -eq $true) {
        $label = "$($task.TaskPath)$($task.TaskName)"
        if ($PSCmdlet.ShouldProcess($label, "Enable scheduled task")) {
            Enable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-Null
        }
    }
}
Write-Output "WINDOWS_PROJECT_TASKS_RESTORED backup=$($latest.FullName)"

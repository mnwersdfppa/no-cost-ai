---
description: Retry OpenClaw recovery through the Windows OpenCode CLI and existing SSH keys
agent: openclaw-recovery
---

Run the following entrypoint exactly once from the repository root:

```powershell
$runner = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell.exe" }
& $runner -NoProfile -ExecutionPolicy Bypass -File "./recovery/opencode-docker/Start-OpenClaw-Recovery.ps1" -PayloadPath ".private/pi-recovery.sh"
exit $LASTEXITCODE
```

Do not edit files and do not retry automatically. Docker is a validator only; actual execution must occur through the Windows host's existing authenticated SSH route.

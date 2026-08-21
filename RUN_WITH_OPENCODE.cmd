@echo off
setlocal
cd /d "%~dp0"

where opencode >nul 2>nul
if errorlevel 1 (
  echo OPENCODE_CLI_MISSING
  echo Install with: npm install -g opencode-ai
  exit /b 2
)

if not exist ".private\pi-recovery.sh" (
  echo PRIVATE_PAYLOAD_MISSING
  exit /b 3
)

opencode run --agent openclaw-recovery --dir "%CD%" "Run the project recovery command exactly once by invoking the approved Start-OpenClaw-Recovery.ps1 entrypoint with .private/pi-recovery.sh. Do not edit files, do not alter Tailscale policy, and do not retry after failure. Return only the OPENCODE_RECOVERY result and receipt path."
exit /b %ERRORLEVEL%

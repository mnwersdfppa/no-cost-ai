@echo off
setlocal
set "PINNED_COMMIT=00a1f2a8c04f6b44f7ef26108943410e5ad84692"
set "SCRIPT_URL=https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/%PINNED_COMMIT%/scripts/Prepare-OpenClaw-PC-Primary.ps1"

echo [OpenClaw PC Primary] Safe preflight only.
echo - n8n remains sole operational scheduler
echo - OpenClaw native cron will be disabled
echo - Raspberry Pi will not be modified
echo - no reboot, no data deletion, no second Telegram poller

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $u='%SCRIPT_URL%'; $p=Join-Path $env:TEMP 'Prepare-OpenClaw-PC-Primary.ps1'; Invoke-WebRequest -UseBasicParsing $u -OutFile $p; & $p"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo PC_PRIMARY_PREFLIGHT_FAILED exit=%RC%
  exit /b %RC%
)

echo PC_PRIMARY_PREFLIGHT_COMPLETE
exit /b 0

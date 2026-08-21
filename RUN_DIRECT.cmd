@echo off
setlocal
cd /d "%~dp0"

where pwsh >nul 2>nul
if not errorlevel 1 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File ".\recovery\opencode-docker\Start-OpenClaw-Recovery.ps1" -PayloadPath ".private\pi-recovery.sh"
  exit /b %ERRORLEVEL%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\recovery\opencode-docker\Start-OpenClaw-Recovery.ps1" -PayloadPath ".private\pi-recovery.sh"
exit /b %ERRORLEVEL%

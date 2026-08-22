@echo off
setlocal EnableExtensions

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
  exit /b
)

set "PIN=06d026db99a9e4bb53c48728033b77a3ffe29d62"
set "BASE=https://raw.githubusercontent.com/mnwersdfppa/no-cost-ai/%PIN%"
set "TMP=%TEMP%\openclaw-pc-primary-%RANDOM%"
mkdir "%TMP%" >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "Invoke-WebRequest -UseBasicParsing '%BASE%/scripts/Enable-OpenClaw-PC-Tailnet-SSH.ps1' -OutFile '%TMP%\Enable-OpenClaw-PC-Tailnet-SSH.ps1';" ^
  "Invoke-WebRequest -UseBasicParsing '%BASE%/scripts/Prepare-OpenClaw-PC-Primary.ps1' -OutFile '%TMP%\Prepare-OpenClaw-PC-Primary.ps1';" ^
  "& '%TMP%\Enable-OpenClaw-PC-Tailnet-SSH.ps1';" ^
  "& '%TMP%\Prepare-OpenClaw-PC-Primary.ps1'"

set "RC=%errorlevel%"
if "%RC%"=="0" (
  echo PC_PRIMARY_AND_TAILNET_SSH_LOCAL_READY
) else (
  echo PC_PRIMARY_AND_TAILNET_SSH_BLOCKED exit=%RC%
)

rmdir /s /q "%TMP%" >nul 2>&1
exit /b %RC%

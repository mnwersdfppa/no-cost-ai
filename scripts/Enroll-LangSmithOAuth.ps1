[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EnrollmentUrl,

    [Parameter(Mandatory = $true)]
    [string]$EnrollmentToken,

    [string]$ProfileName = "openclaw"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Fail([string]$Reason, [int]$Code = 40) {
    Write-Error "LANGSMITH_OAUTH_ENROLLMENT_BLOCKED reason=$Reason"
    exit $Code
}

if (-not ($EnrollmentUrl -match '^https://dpllasnpfskyyyzebyal\.supabase\.co/functions/v1/')) {
    Fail "untrusted_enrollment_url"
}
if ($EnrollmentToken.Length -lt 32 -or $EnrollmentToken.Length -gt 512) {
    Fail "invalid_enrollment_capability"
}

$langsmith = Get-Command langsmith -ErrorAction SilentlyContinue
if (-not $langsmith) {
    $installer = Join-Path $env:TEMP "langsmith-cli-install.ps1"
    Invoke-WebRequest -UseBasicParsing -Uri "https://cli.langsmith.com/install.ps1" -OutFile $installer
    $length = (Get-Item $installer).Length
    if ($length -lt 100 -or $length -gt 1048576) {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
        Fail "official_cli_installer_size_invalid"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
    $installerExit = $LASTEXITCODE
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    if ($installerExit -ne 0) {
        Fail "official_cli_installer_failed"
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (($machinePath, $userPath) -join ";")
    $langsmith = Get-Command langsmith -ErrorAction SilentlyContinue
    if (-not $langsmith) {
        Fail "langsmith_cli_install_failed"
    }
}

# The only interactive provider step. This opens the official LangSmith OAuth
# page and stores refreshable tokens in the named local profile.
& $langsmith.Source auth login --profile $ProfileName
if ($LASTEXITCODE -ne 0) {
    Fail "langsmith_oauth_login_failed"
}

$configPath = Join-Path $env:USERPROFILE ".langsmith\config.json"
if (-not (Test-Path $configPath -PathType Leaf)) {
    Fail "langsmith_profile_file_missing"
}

& icacls.exe $configPath /inheritance:r /grant:r "$env:USERNAME`:(F)" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Fail "langsmith_profile_acl_failed"
}

& $langsmith.Source --profile $ProfileName project list --limit 1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Fail "langsmith_oauth_profile_verification_failed"
}

$profileJson = [System.IO.File]::ReadAllText(
    $configPath,
    [System.Text.Encoding]::UTF8
)
if ([System.Text.Encoding]::UTF8.GetByteCount($profileJson) -gt 131072) {
    Fail "langsmith_profile_too_large"
}

$body = @{ profile_json = $profileJson } | ConvertTo-Json -Compress
$invokeParameters = @{
    Method = "Post"
    Uri = $EnrollmentUrl
    Headers = @{ "x-langsmith-enrollment-token" = $EnrollmentToken }
    ContentType = "application/json"
    Body = $body
}
$response = Invoke-RestMethod @invokeParameters

if ($response.ok -ne $true -or $response.state -ne "oauth_profile_enrolled") {
    Fail "supabase_vault_enrollment_failed"
}

$receiptDir = Join-Path $env:USERPROFILE ".openclaw\receipts"
New-Item -ItemType Directory -Force -Path $receiptDir | Out-Null
$receipt = @{
    completed_at = [DateTimeOffset]::UtcNow.ToString("o")
    result = "langsmith_oauth_profile_enrolled"
    profile = $ProfileName
    storage = "supabase_vault"
    local_profile_path = $configPath
    profile_values_included = $false
    secret_values_included = $false
}
$receiptPath = Join-Path $receiptDir "langsmith-oauth-enrollment.json"
$receipt | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -Path $receiptPath
& icacls.exe $receiptPath /inheritance:r /grant:r "$env:USERNAME`:(F)" | Out-Null

$EnrollmentToken = ""
$body = ""
$profileJson = ""
$invokeParameters.Clear()
Write-Output "LANGSMITH_OAUTH_ENROLLED storage=supabase_vault receipt=$receiptPath"

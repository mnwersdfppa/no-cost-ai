[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path $env:USERPROFILE '.openclaw'
$backupRoot = Join-Path $root 'backups'
$receiptDir = Join-Path $root 'receipts'
$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$backup = Join-Path $backupRoot "pc-tailnet-ssh-$stamp"
$receipt = Join-Path $receiptDir 'pc-tailnet-ssh-v1.json'
New-Item -ItemType Directory -Force -Path $backupRoot,$receiptDir,$backup | Out-Null

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'ADMINISTRATOR_REQUIRED'
}

if (-not (Get-Command tailscale.exe -ErrorAction SilentlyContinue)) {
    throw 'TAILSCALE_CLI_NOT_FOUND'
}

$tsStatusRaw = & tailscale.exe status --json 2>$null | Out-String
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tsStatusRaw)) {
    throw 'TAILSCALE_STATUS_UNAVAILABLE'
}
$ts = $tsStatusRaw | ConvertFrom-Json
if ($ts.BackendState -ne 'Running') {
    throw 'TAILSCALE_NOT_RUNNING'
}

$tailscaleIPv4 = @(& tailscale.exe ip -4 2>$null) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($tailscaleIPv4)) {
    throw 'TAILSCALE_IPV4_NOT_FOUND'
}

$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
$installedNow = $false
if ($cap.State -ne 'Installed') {
    $result = Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    if ($result.RestartNeeded) {
        throw 'OPENSSH_INSTALL_REQUIRES_RESTART_MANUAL_REVIEW'
    }
    $installedNow = $true
}

$previousStartup = (Get-Service sshd -ErrorAction Stop).StartType.ToString()
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue |
    Export-Clixml -Path (Join-Path $backup 'default-openssh-firewall-rule.xml')

Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

$scopedRule = 'OpenClaw-Tailscale-SSH-In-TCP'
if (-not (Get-NetFirewallRule -Name $scopedRule -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $scopedRule `
        -DisplayName 'OpenClaw PC SSH over Tailscale only' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
        -LocalPort 22 -RemoteAddress '100.64.0.0/10','fd7a:115c:a1e0::/48' | Out-Null
} else {
    Enable-NetFirewallRule -Name $scopedRule | Out-Null
}

# Only remove the broad default exposure after Tailscale is confirmed online
# and the scoped tailnet rule exists. The rule is disabled, never deleted.
$defaultRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
$defaultRuleDisabled = $false
if ($null -ne $defaultRule) {
    Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' | Out-Null
    $defaultRuleDisabled = $true
}

$localSsh = Test-NetConnection -ComputerName 127.0.0.1 -Port 22 -InformationLevel Quiet
if (-not $localSsh) {
    if ($defaultRuleDisabled) { Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' | Out-Null }
    Disable-NetFirewallRule -Name $scopedRule -ErrorAction SilentlyContinue | Out-Null
    Set-Service -Name sshd -StartupType $previousStartup
    throw 'LOCAL_SSH_VERIFY_FAILED_ROLLBACK_APPLIED'
}

$payload = [ordered]@{
    completed_at = [DateTimeOffset]::UtcNow.ToString('o')
    result = 'pc_tailnet_ssh_ready_local_verification_complete'
    contract_version = 1
    tailscale_backend_running = $true
    tailscale_ipv4 = [string]$tailscaleIPv4
    openssh_server_present = $true
    openssh_server_installed_now = $installedNow
    sshd_running = ((Get-Service sshd).Status -eq 'Running')
    sshd_startup = (Get-Service sshd).StartType.ToString()
    localhost_port_22_verified = $true
    tailnet_firewall_rule = $scopedRule
    allowed_remote_ipv4 = '100.64.0.0/10'
    allowed_remote_ipv6 = 'fd7a:115c:a1e0::/48'
    broad_default_openssh_rule_disabled = $defaultRuleDisabled
    public_internet_ssh_intentionally_enabled = $false
    tailscale_acl_modified = $false
    host_rebooted = $false
    secret_values_included = $false
    remote_tailnet_connection_receipt_required = $true
    rollback = 'scripts/Disable-OpenClaw-PC-Tailnet-SSH.ps1'
}
$payload | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $receipt
Write-Output "PC_TAILNET_SSH_LOCAL_READY tailscale_ip=$tailscaleIPv4 receipt=$receipt"

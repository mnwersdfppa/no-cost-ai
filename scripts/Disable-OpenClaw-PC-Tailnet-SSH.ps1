[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scopedRule = 'OpenClaw-Tailscale-SSH-In-TCP'
if (Get-NetFirewallRule -Name $scopedRule -ErrorAction SilentlyContinue) {
    Disable-NetFirewallRule -Name $scopedRule | Out-Null
}
if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
    Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' | Out-Null
}

$root = Join-Path $env:USERPROFILE '.openclaw'
$receiptDir = Join-Path $root 'receipts'
New-Item -ItemType Directory -Force -Path $receiptDir | Out-Null
[ordered]@{
    completed_at = [DateTimeOffset]::UtcNow.ToString('o')
    result = 'pc_tailnet_ssh_scoped_rule_disabled'
    scoped_tailnet_rule_disabled = $true
    default_openssh_rule_reenabled_if_present = $true
    sshd_removed = $false
    tailscale_modified = $false
    host_rebooted = $false
    secret_values_included = $false
} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $receiptDir 'pc-tailnet-ssh-rollback-v1.json')

Write-Output 'PC_TAILNET_SSH_ROLLBACK_COMPLETE'

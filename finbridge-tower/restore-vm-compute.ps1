<#
.SYNOPSIS
Restores compute health on the FinBridge tower Linux VM by stopping stress-ng.

.DESCRIPTION
This script stops stress-ng on the Linux VM and verifies that no stress-ng process remains.
#>

param(
    [string]$ResourceGroupName,
    [string]$VmName = "vm-finbridge-prod"
)

Set-Location $PSScriptRoot

function Get-TerraformOutput {
    param([string]$Name)
    $value = terraform output -raw $Name 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Terraform output '$Name' is not available. Ensure this script runs in the finbridge-tower directory and Terraform has been initialized."
        exit 1
    }
    return $value.Trim()
}

if (-not $ResourceGroupName) {
    $ResourceGroupName = Get-TerraformOutput -Name "resource_group_name"
}

Write-Host "Restoring VM compute health on '$VmName' in resource group '$ResourceGroupName'."

$scripts = @(
    "#!/bin/bash",
    "set -e",
    "if [ -f /tmp/stress-ng.pid ]; then",
    '  pid=$(cat /tmp/stress-ng.pid)',
    '  echo "Stopping stress-ng process ID: $pid"',
    "  sudo kill $pid || true",
    "  rm -f /tmp/stress-ng.pid",
    "fi",
    "sudo pkill -f stress-ng || true",
    "sleep 2",
    "if pgrep -f stress-ng > /dev/null; then",
    "  echo 'stress-ng is still running'",
    "  exit 1",
    "fi",
    "echo 'stress-ng stopped successfully'"
)

az vm run-command invoke `
    --command-id RunShellScript `
    --name $VmName `
    --resource-group $ResourceGroupName `
    --scripts $scripts

if ($LASTEXITCODE -ne 0) {
    Write-Error "VM compute restore failed."
    exit 1
}

Write-Host "VM compute restore succeeded."

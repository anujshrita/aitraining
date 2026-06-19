<#
.SYNOPSIS
Injects a compute resource exhaustion fault on the FinBridge tower Linux VM.

.DESCRIPTION
This script uses Azure VM Run Command to install stress-ng and generate sustained
CPU and memory pressure on the Linux VM.
#>

param(
    [string]$ResourceGroupName,
    [string]$VmName = "vm-finbridge-prod",
    [int]$CpuWorkers = 2,
    [string]$MemoryBytes = "4G",
    [int]$DurationSeconds = 600
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

Write-Host "Injecting VM compute fault on '$VmName' in resource group '$ResourceGroupName'."

$scripts = @(
    "#!/bin/bash",
    "set -e",
    "cat > /tmp/fault-inject.sh <<'EOF'",
    "#!/bin/bash",
    "set -e",
    "echo 'Installing stress-ng'",
    "sudo apt-get update -qq",
    "sudo apt-get install -y stress-ng",
    "echo 'Starting stress-ng with $CpuWorkers CPU workers and $MemoryBytes memory load for $DurationSeconds seconds'",
    "nohup sudo stress-ng --cpu $CpuWorkers --vm 1 --vm-bytes $MemoryBytes --timeout ${DurationSeconds}s --metrics-brief > /tmp/stress-ng.out 2>&1 &",
    "echo \$! > /tmp/stress-ng.pid",
    "echo 'Fault injection complete.'",
    "EOF",
    "chmod +x /tmp/fault-inject.sh",
    "sudo /tmp/fault-inject.sh",
    "sudo ls -l /tmp/stress-ng.out /tmp/stress-ng.pid || true"
)

az vm run-command invoke `
    --command-id RunShellScript `
    --name $VmName `
    --resource-group $ResourceGroupName `
    --scripts $scripts

if ($LASTEXITCODE -ne 0) {
    Write-Error "Fault injection failed."
    exit 1
}

Write-Host "VM compute fault injection succeeded."

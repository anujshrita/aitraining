<#
.SYNOPSIS
Diagnoses VM compute pressure and makes a capacity recommendation.

.DESCRIPTION
This script collects CPU and memory utilization from the Linux VM and Azure Monitor,
then provides a capacity recommendation based on observed load.
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

Write-Host "Collecting VM compute diagnostics for '$VmName' in resource group '$ResourceGroupName'."

$vm = az vm show --name $VmName --resource-group $ResourceGroupName --query id -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vm)) {
    Write-Error "Failed to retrieve VM resource ID."
    exit 1
}

$metricJson = az monitor metrics list --resource $vm --metric "Percentage CPU" --aggregation Average --interval PT5M --top 1 -o json
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Unable to retrieve Azure Monitor CPU metrics."
} else {
    $cpuMetric = $metricJson | ConvertFrom-Json
    $avgCpu = $cpuMetric.value[0].timeseries[0].data | Where-Object { $_.average -ne $null } | Select-Object -First 1 -ExpandProperty average
    if ($avgCpu -ne $null) {
        Write-Host "Azure Monitor average CPU (recent): $([math]::Round($avgCpu,2))%"
    } else {
        Write-Warning "Azure Monitor did not return a recent CPU average."
    }
}

$scripts = @(
    "#!/bin/bash",
    "set -e",
    "echo '=== top summary ==='",
    "top -bn1 | head -n 5",
    "echo '=== memory usage ==='",
    "free -m",
    "echo '=== load average ==='",
    "cat /proc/loadavg"
)

Write-Host "Running remote diagnostics inside the VM..."

$remoteOutput = az vm run-command invoke `
    --command-id RunShellScript `
    --name $VmName `
    --resource-group $ResourceGroupName `
    --scripts $scripts --query value[0].message -o tsv

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to collect remote diagnostics from the VM."
    exit 1
}

Write-Host $remoteOutput

$remoteLines = $remoteOutput -split "`n"
$cpuLine = $remoteLines | Where-Object { $_ -match '%Cpu' } | Select-Object -First 1
$cpuUser = $null
if ($cpuLine -match '([0-9]+(?:\.[0-9]+)?)\s+us') {
    $cpuUser = [double]$Matches[1]
    Write-Host "Remote VM user CPU usage: $cpuUser%"
}

if ($cpuUser -ne $null) {
    if ($cpuUser -ge 80) {
        Write-Host "RECOMMENDATION: Sustained high CPU usage on the VM. Scale to a larger SKU such as Standard_B4ms or Standard_D2s_v3."
    } elseif ($cpuUser -ge 60) {
        Write-Host "RECOMMENDATION: Elevated CPU load observed on the VM. Monitor closely and consider capacity increase if sustained."
    } else {
        Write-Host "RECOMMENDATION: Remote VM CPU utilization appears within normal bounds. No immediate capacity change required."
    }
} elseif ($avgCpu -ne $null) {
    if ($avgCpu -ge 80) {
        Write-Host "RECOMMENDATION: Azure Monitor CPU saturation detected. Consider scaling the VM."
    } elseif ($avgCpu -ge 60) {
        Write-Host "RECOMMENDATION: Elevated Azure Monitor CPU load observed. Monitor further."
    } else {
        Write-Host "RECOMMENDATION: Azure Monitor CPU utilization is within normal bounds. No immediate capacity change required."
    }
} else {
    Write-Host "RECOMMENDATION: Unable to determine compute pressure from metrics. Review VM diagnostics manually."
}

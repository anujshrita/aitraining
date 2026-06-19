<#
.SYNOPSIS
Restores Azure SQL connectivity by ensuring the tower SQL firewall rule exists.

.DESCRIPTION
This restore script recreates or updates the Azure SQL firewall rule used by the FinBridge tower.
It is intended to be run before any fault injection, proving rollback capability.
#>

param(
    [string]$ResourceGroupName,
    [string]$SqlServerFqdn,
    [string]$FirewallRuleName = "allow-ssh-cidr",
    [string]$StartIpAddress = "0.0.0.0",
    [string]$EndIpAddress = "255.255.255.255"
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

if (-not $SqlServerFqdn) {
    $SqlServerFqdn = Get-TerraformOutput -Name "sql_server_fqdn"
}

$SqlServerName = $SqlServerFqdn.Split('.')[0]

Write-Host "Restoring Azure SQL firewall rule '$FirewallRuleName' on server '$SqlServerName' in resource group '$ResourceGroupName'."

$existingRule = az sql server firewall-rule show `
    --resource-group $ResourceGroupName `
    --server $SqlServerName `
    --name $FirewallRuleName 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "Firewall rule exists. Updating its IP range to $StartIpAddress - $EndIpAddress."
    az sql server firewall-rule update `
        --resource-group $ResourceGroupName `
        --server $SqlServerName `
        --name $FirewallRuleName `
        --start-ip-address $StartIpAddress `
        --end-ip-address $EndIpAddress | Out-Null
} else {
    Write-Host "Firewall rule not found. Creating it with IP range $StartIpAddress - $EndIpAddress."
    az sql server firewall-rule create `
        --resource-group $ResourceGroupName `
        --server $SqlServerName `
        --name $FirewallRuleName `
        --start-ip-address $StartIpAddress `
        --end-ip-address $EndIpAddress | Out-Null
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to restore the Azure SQL firewall rule."
    exit 1
}

Write-Host "Restore complete. Verifying firewall rule state..."
az sql server firewall-rule show `
    --resource-group $ResourceGroupName `
    --server $SqlServerName `
    --name $FirewallRuleName

if ($LASTEXITCODE -ne 0) {
    Write-Error "Firewall rule verification failed after restore."
    exit 1
}

Write-Host "Azure SQL firewall rule restored successfully."

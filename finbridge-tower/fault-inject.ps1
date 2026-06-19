<#
.SYNOPSIS
Injects a SQL connectivity fault by deleting the Azure SQL firewall rule.

.DESCRIPTION
This fault script removes the SQL firewall rule used by the FinBridge tower, simulating a database connectivity outage.
#>

param(
    [string]$ResourceGroupName,
    [string]$SqlServerFqdn,
    [string]$FirewallRuleName = "allow-ssh-cidr"
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

Write-Host "Injecting fault: removing Azure SQL firewall rule '$FirewallRuleName' on server '$SqlServerName'."

$ruleCheck = az sql server firewall-rule show `
    --resource-group $ResourceGroupName `
    --server $SqlServerName `
    --name $FirewallRuleName 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Firewall rule '$FirewallRuleName' does not exist; fault injection is a no-op."
    exit 0
}

az sql server firewall-rule delete `
    --resource-group $ResourceGroupName `
    --server $SqlServerName `
    --name $FirewallRuleName

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to delete the SQL firewall rule. Fault injection did not complete."
    exit 1
}

Write-Host "Fault injection complete. SQL firewall rule '$FirewallRuleName' has been removed."

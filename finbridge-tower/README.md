# FinBridge Tower Terraform

This workspace creates a minimal FinBridge tower on Azure with:

- Resource Group
- Virtual Network and Application Subnet
- Network Security Group for SSH containment
- Public IP and Linux bastion VM using SSH key authentication
- Azure Storage Account for tower artifacts and logs
- Azure Database for PostgreSQL Flexible Server

## Gate checks

1. `terraform fmt -check`
2. `terraform init`
3. `terraform validate`
4. `terraform plan -out=tfplan`
5. `terraform apply tfplan`

## Notes

- If you do not provide `ssh_public_key`, Terraform generates a temporary RSA key pair.
- Use the generated private key output for SSH access if a public key was not provided.
- The PostgreSQL admin password is generated automatically and marked sensitive.

## Phase 2: Fault injection and restore

Two PowerShell scripts were added for the FinBridge tower:

- `restore.ps1` — restores the Azure SQL firewall rule before injecting a fault.
- `fault-inject.ps1` — deletes the Azure SQL firewall rule to simulate a database connectivity outage.

The restore script was tested successfully before the fault script was committed.

## Phase 5: VM compute fault and capacity decision

Three PowerShell scripts were added for VM compute degradation testing:

- `fault-inject-vm-compute.ps1` — injects sustained CPU and memory pressure on the Linux VM using stress-ng.
- `restore-vm-compute.ps1` — stops stress-ng and verifies compute health recovery.
- `diagnose-vm-compute.ps1` — collects remote VM compute diagnostics and provides a capacity recommendation.

The compute restore script was verified before any fault injection.

## Documentation

- `incident-rca.md` — RCA for SQL firewall rule fault injection
- `vm-compute-incident-rca.md` — RCA for VM compute degradation fault injection

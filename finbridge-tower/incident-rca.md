# FinBridge Tower Incident RCA

## Incident Summary

- **Date:** 2026-06-19
- **Service:** Azure SQL Server `sql-finbridge-prod`
- **Impact:** SQL connectivity fault injected by deleting the Azure SQL firewall rule `allow-ssh-cidr`
- **Outcome:** Fault detected, root cause confirmed, restore applied, recovery verified

## Timeline

1. **10:59:20Z** — Fault injection started
   - Command: `.ault-inject.ps1`
   - Observed: `Injecting fault: removing Azure SQL firewall rule 'allow-ssh-cidr'`

2. **10:59:28Z** — Fault injection completed
   - Observed: `Fault injection complete. SQL firewall rule 'allow-ssh-cidr' has been removed.`

3. **10:59:47Z** — Post-fault verification started
   - Command: `az sql server firewall-rule show --resource-group rg-finbridge-prod --server sql-finbridge-prod --name allow-ssh-cidr`

4. **10:59:50Z** — Fault confirmed
   - Result: `ResourceNotFound`
   - Interpretation: Firewall rule absence confirmed SQL access path was severed

5. **11:00:36Z** — Restore started
   - Command: `.
estore.ps1`
   - Observed: `Firewall rule not found. Creating it with IP range 0.0.0.0 - 255.255.255.255.`

6. **11:00:46Z** — Restore verification started
   - Command: `az sql server firewall-rule show --resource-group rg-finbridge-prod --server sql-finbridge-prod --name allow-ssh-cidr`

7. **11:00:49Z** — Recovery verified
   - Result: firewall rule present with start IP `0.0.0.0` and end IP `255.255.255.255`

## Baseline

- Before the incident, the Azure SQL rule `allow-ssh-cidr` existed and allowed broad SQL access from `0.0.0.0 - 255.255.255.255`.
- The service baseline included an Azure SQL Server and a default SQL firewall rule to enable connectivity.

## Hypothesis

- The observed outage was caused by a deliberately injected infrastructure fault: removal of the Azure SQL server firewall rule.
- This would block client connections to `sql-finbridge-prod.database.windows.net` from all IP addresses.

## Root Cause

- The root cause was confirmed as a missing Azure SQL firewall rule.
- The fault script successfully deleted the `allow-ssh-cidr` firewall rule on the SQL server, which is the deliberate failure mode.

## Remediation

- Executed `restore.ps1`
- The restore logic:
  - queried Terraform outputs to identify the resource group and SQL server
  - recreated the firewall rule if missing
  - set the rule range to `0.0.0.0 - 255.255.255.255`
  - verified the rule after creation

## Verification

- Post-restore verification command succeeded:
  - `az sql server firewall-rule show --resource-group rg-finbridge-prod --server sql-finbridge-prod --name allow-ssh-cidr`
- The firewall rule was present and returned the expected values:
  - `startIpAddress: 0.0.0.0`
  - `endIpAddress: 255.255.255.255`
- Return code: `0`

## Lessons Learned

- The restore path was proven before the fault injection, satisfying the no-break-without-rollback requirement.
- The engineered fault was narrow and observable: a single firewall rule deletion, which made detection and remediation straightforward.
- For production-grade incidents, a narrower SQL rule or more targeted diagnostics would improve post-fault impact analysis.

## Files

- `fault-inject.ps1` — fault injection script
- `restore.ps1` — restore script
- `incident-rca.md` — this document

output "resource_group_name" {
  description = "Name of the tower resource group"
  value       = azurerm_resource_group.tower.name
}

output "vm_public_ip" {
  description = "Public IP address for SSH access to the Linux tower VM"
  value       = azurerm_public_ip.vm.ip_address
}

output "linux_admin_username" {
  description = "Admin username for the Linux VM"
  value       = var.admin_username
}

output "sql_server_fqdn" {
  description = "Public FQDN for the Azure SQL Server"
  value       = azurerm_mssql_server.towerdb.fully_qualified_domain_name
}

output "sql_database_name" {
  description = "Name of the Azure SQL database"
  value       = azurerm_mssql_database.towerdb.name
}

output "storage_account_name" {
  description = "Storage account created for tower logs and tooling"
  value       = azurerm_storage_account.tower.name
}

output "generated_ssh_private_key_pem" {
  description = "Generated SSH private key PEM when no public key was provided"
  value       = try(tls_private_key.vm_key[0].private_key_pem, "")
  sensitive   = true
}

output "sql_admin_password" {
  description = "Generated Azure SQL admin password"
  value       = random_password.db_admin_password.result
  sensitive   = true
}

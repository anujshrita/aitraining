variable "environment" {
  description = "Environment name for tower resources"
  type        = string
  default     = "prod"
}

variable "location" {
  description = "Azure region for the tower"
  type        = string
  default     = "eastus"
}

variable "admin_username" {
  description = "SSH user for Linux bastion VM"
  type        = string
  default     = "finopsadmin"
}

variable "ssh_public_key" {
  description = "Public SSH key for Linux VM access. If omitted, Terraform generates a temporary key pair."
  type        = string
  default     = ""
}

variable "allowed_ssh_cidr" {
  description = "CIDR range allowed to access the Linux jump VM over SSH"
  type        = string
  default     = "0.0.0.0/0"
}

variable "db_admin_username" {
  description = "Administrator username for Azure SQL Server"
  type        = string
  default     = "finbridgeadmin"
}

variable "allowed_db_cidr_start" {
  description = "Start of allowed IP range for SQL Server firewall rules"
  type        = string
  default     = "0.0.0.0"
}

variable "allowed_db_cidr_end" {
  description = "End of allowed IP range for SQL Server firewall rules"
  type        = string
  default     = "255.255.255.255"
}

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  name_prefix    = "finbridge-${var.environment}"
  ssh_public_key = var.ssh_public_key != "" ? var.ssh_public_key : tls_private_key.vm_key[0].public_key_openssh
}

resource "random_string" "storage_suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "tls_private_key" "vm_key" {
  count      = var.ssh_public_key == "" ? 1 : 0
  algorithm  = "RSA"
  rsa_bits   = 4096
}

resource "azurerm_resource_group" "tower" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags = {
    project = "finbridge-tower"
    owner   = "ai-ops"
  }
}

resource "azurerm_virtual_network" "tower" {
  name                = "vnet-${local.name_prefix}"
  location            = azurerm_resource_group.tower.location
  resource_group_name = azurerm_resource_group.tower.name
  address_space       = ["10.10.0.0/16"]
  tags                = azurerm_resource_group.tower.tags
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.tower.name
  virtual_network_name = azurerm_virtual_network.tower.name
  address_prefixes     = ["10.10.1.0/24"]
}

resource "azurerm_network_security_group" "app" {
  name                = "nsg-${local.name_prefix}"
  location            = azurerm_resource_group.tower.location
  resource_group_name = azurerm_resource_group.tower.name
  tags                = azurerm_resource_group.tower.tags

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowOutboundAll"
    priority                   = 4000
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_public_ip" "vm" {
  name                = "pip-${local.name_prefix}"
  location            = azurerm_resource_group.tower.location
  resource_group_name = azurerm_resource_group.tower.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = azurerm_resource_group.tower.tags
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-${local.name_prefix}"
  location            = azurerm_resource_group.tower.location
  resource_group_name = azurerm_resource_group.tower.name
  tags                = azurerm_resource_group.tower.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_linux_virtual_machine" "app" {
  name                  = "vm-${local.name_prefix}"
  resource_group_name   = azurerm_resource_group.tower.name
  location              = azurerm_resource_group.tower.location
  size                  = "Standard_B2ms"
  admin_username        = var.admin_username
  disable_password_authentication = true
  network_interface_ids = [azurerm_network_interface.vm.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = local.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 32
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  boot_diagnostics {}
  tags = azurerm_resource_group.tower.tags
}

resource "azurerm_storage_account" "tower" {
  name                     = "fbtower${random_string.storage_suffix.result}"
  resource_group_name      = azurerm_resource_group.tower.name
  location                 = azurerm_resource_group.tower.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  access_tier              = "Hot"
  tags                     = azurerm_resource_group.tower.tags
}

resource "azurerm_mssql_server" "towerdb" {
  name                         = "sql-${local.name_prefix}"
  resource_group_name          = azurerm_resource_group.tower.name
  location                     = azurerm_resource_group.tower.location
  version                      = "12.0"
  administrator_login          = var.db_admin_username
  administrator_login_password = random_password.db_admin_password.result
  public_network_access_enabled = true
  tags                         = azurerm_resource_group.tower.tags
}

resource "azurerm_mssql_database" "towerdb" {
  name      = "finbridge-data"
  server_id = azurerm_mssql_server.towerdb.id
  sku_name  = "S0"
  max_size_gb = 5
  collation = "SQL_Latin1_General_CP1_CI_AS"
}

resource "azurerm_mssql_firewall_rule" "db_access" {
  name             = "allow-ssh-cidr"
  server_id        = azurerm_mssql_server.towerdb.id
  start_ip_address = var.allowed_db_cidr_start
  end_ip_address   = var.allowed_db_cidr_end
}

resource "random_password" "db_admin_password" {
  length           = 24
  special          = true
  override_special = "!@#$%&*()-_=+[]{}<>?"
}

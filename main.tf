terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.50.0"
    }
  }
}

provider "azurerm" {
  client_id       = try(env("AZURE_CLIENT_ID"), "")
  client_secret   = try(env("AZURE_CLIENT_SECRET"), "")
  tenant_id       = try(env("AZURE_TENANT_ID"), "")
  subscription_id = try(env("AZURE_SUBSCRIPTION_ID"), "")

  features {}
}

resource "azurerm_resource_group" "resourcegroup" {
  name     = "devtest-resources"
  location = "northeurope"
}

resource "azurerm_virtual_network" "vnet_main" {
  name                = "vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.resourcegroup.location
  resource_group_name = azurerm_resource_group.resourcegroup.name
}

resource "azurerm_subnet" "vnet_sub" {
  name                 = "subnetname"
  resource_group_name  = azurerm_resource_group.resourcegroup.name
  virtual_network_name = azurerm_virtual_network.vnet_main.name
  address_prefixes     = ["10.0.2.0/24"]
  service_endpoints    = ["Microsoft.Sql", "Microsoft.Storage"]
}

resource "azurerm_storage_account" "storage_account" {
  name                     = "storageaccascode232"
  resource_group_name      = azurerm_resource_group.resourcegroup.name
  location                 = azurerm_resource_group.resourcegroup.location
  account_tier             = "Standard"
  account_replication_type = "GRS"

  network_rules {
    default_action             = "Deny"
    ip_rules                   = ["109.247.234.158"]
    virtual_network_subnet_ids = [azurerm_subnet.vnet_sub.id]
  }

  min_tls_version = "TLS1_2"

  tags = {
    identity = "dev"
  }
}

resource "azurerm_private_endpoint" "private_EP" {
  name                = "private-endpoint"
  location            = azurerm_resource_group.resourcegroup.location
  resource_group_name = azurerm_resource_group.resourcegroup.name
  subnet_id           = azurerm_subnet.vnet_sub.id

  private_service_connection {
    name                           = "private-service-connection"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_storage_account.storage_account.id
    subresource_names              = ["blob"]
  }
}

resource "null_resource" "pim_pag_config" {
  triggers = {
    storage_account_id = azurerm_storage_account.storage_account.id
  }

  provisioner "local-exec" {
    command     = <<-EOT
      $ErrorActionPreference = 'Stop'

      # Variables
      $resourceGroupName = "devtest-resources"
      $storageAccountName = "storageaccascode232"
      $pagName = "PAG-SA-Blob"
      $roleName = "Storage-Blob-Data"

      # Get necessary IDs
      $subscriptionId = (az account show --query id -o tsv)
      $storageAccountId = (az storage account show --name $storageAccountName --resource-group $resourceGroupName --query id -o tsv)
      $userObjectId = "8834643c-cf97-4e13-9970-277dfa04d91f"

      # Create PAG group
      az ad group create --display-name $pagName --mail-nickname $pagName

      # Get PAG group object ID
      $groupObjectId = (az ad group list --display-name $pagName --query "[0].objectId" -o tsv)

      # Add current user as a member of PAG group
      az ad group member add --group $pagName --member-id $userObjectId

      # Get role definition ID
      $roleDefinitionId = (az role definition list --name "$roleName" --query "[0].name" -o tsv)

      # Assign PAG group as eligible for the role
      az rest --method post --uri "https://management.azure.com/$storageAccountId/providers/Microsoft.Authorization/roleAssignments?api-version=2021-04-01-preview" --headers "Content-Type=application/json" --body "{'properties': {'roleDefinitionId': '$roleDefinitionId', 'principalId': '$groupObjectId', 'principalType': 'Group', 'canDelegate': true, 'description': '$pagName', 'condition': null, 'conditionVersion': '2.0', 'justInTimeAccessPolicy': {'timeWindowInMinutes': 60, 'dataConsistency': 'Enabled'}}}"
    EOT
    interpreter = ["cmd", "/C", "powershell.exe"]
  }
}

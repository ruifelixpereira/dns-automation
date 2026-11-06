data "terraform_remote_state" "foundation" {
  backend = "local"
  config = {
    path = var.foundation_state_path != "" ? var.foundation_state_path : "${path.module}/../../terraform.tfstate"
  }
}

data "azurerm_client_config" "current" {}

locals {
  foundation = data.terraform_remote_state.foundation.outputs
  tags = {
    environment = "demo"
    workload    = "central-private-dns-samples"
    managed-by  = "terraform"
  }
  resource_suffixes = {
    for key, endpoint in var.endpoints :
    key => substr(sha256("${local.foundation.subscription_id}/${local.foundation.name_prefix}/${key}"), 0, 16)
  }
}

resource "azurerm_storage_account" "sample" {
  #checkov:skip=CKV_AZURE_206:Disposable DNS demo uses LRS; no critical data or regional recovery requirement.
  #checkov:skip=CKV_AZURE_59:Scanner checks the deprecated attribute; public_network_access is explicitly Disabled.
  #checkov:skip=CKV_AZURE_33:Queue service is not used; this example exercises Blob DNS only.
  #checkov:skip=CKV_AZURE_36:Trusted-service bypass is deliberately disabled; only private connectivity is allowed.
  #checkov:skip=CKV2_AZURE_33:Scanner cannot trace the conditional per-service endpoint reference; Terraform tests verify it.
  #checkov:skip=CKV2_AZURE_1:No critical data; platform encryption is sufficient for this disposable DNS example.
  for_each = { for key, endpoint in var.endpoints : key => endpoint if endpoint.service == "blob" }

  name                            = "st${local.resource_suffixes[each.key]}"
  resource_group_name             = local.foundation.resource_groups.network
  location                        = local.foundation.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false
  public_network_access           = "Disabled"
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true
  tags                            = local.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["None"]
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
    versioning_enabled = true
  }
}

resource "azurerm_key_vault" "sample" {
  #checkov:skip=CKV2_AZURE_32:Scanner cannot trace the conditional per-service endpoint reference; Terraform tests verify it.
  for_each = { for key, endpoint in var.endpoints : key => endpoint if endpoint.service == "vault" }

  name                          = "kv-${local.resource_suffixes[each.key]}"
  location                      = local.foundation.location
  resource_group_name           = local.foundation.resource_groups.network
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  soft_delete_retention_days    = 7
  purge_protection_enabled      = true
  public_network_access_enabled = false
  tags                          = local.tags

  network_acls {
    default_action = "Deny"
    bypass         = "None"
  }
}

resource "azurerm_private_endpoint" "sample" {
  for_each = var.endpoints

  name                = "pep-${local.foundation.name_prefix}-${each.key}"
  location            = local.foundation.location
  resource_group_name = local.foundation.resource_groups.network
  subnet_id           = local.foundation.private_endpoint_subnet_ids[each.value.network]
  tags                = local.tags

  private_service_connection {
    name                           = "connection-${each.key}"
    private_connection_resource_id = each.value.service == "blob" ? azurerm_storage_account.sample[each.key].id : azurerm_key_vault.sample[each.key].id
    subresource_names              = [each.value.service]
    is_manual_connection           = false
  }

  lifecycle {
    # This child resource belongs exclusively to Policy, not to this Terraform state.
    ignore_changes = [private_dns_zone_group]
  }
}

## Azure-AKS
#
# Terraform Registry : https://registry.terraform.io/namespaces/Azure
# GitHub Repository  : https://github.com/terraform-azurerm-modules
#
provider "azurerm" {

  subscription_id = var.subscription_id
  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id
  partner_id      = var.partner_id
  use_msi         = var.use_msi

  features {}
}

provider "azuread" {
  client_id     = var.client_id
  client_secret = var.client_secret
  tenant_id     = var.tenant_id
}

provider "kubernetes" {
  host                   = module.aks.host
  client_key             = base64decode(module.aks.client_key)
  client_certificate     = base64decode(module.aks.client_certificate)
  cluster_ca_certificate = base64decode(module.aks.cluster_ca_certificate)
}

data "azurerm_subscription" "current" {}

data "azurerm_resource_group" "network_rg" {
  count    = var.vnet_resource_group_name == null ? 0 : 1
  name     = var.vnet_resource_group_name
}

resource "azurerm_resource_group" "aks_rg" {
  count    = var.resource_group_name == null ? 1 : 0
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "aks_rg" {
  count    = var.resource_group_name == null ? 0 : 1
  name     = var.resource_group_name
}
resource "azurerm_proximity_placement_group" "proximity" {
  count = var.node_pools_proximity_placement ? 1 : 0

  name                = "${var.prefix}-ProximityPlacementGroup"
  location            = var.location
  resource_group_name = local.aks_rg.name
  tags                = var.tags
}

resource "azurerm_network_security_group" "nsg" {
  count               = var.nsg_name == null ? 1 : 0
  name                = "${var.prefix}-nsg"
  location            = var.location
  resource_group_name = local.aks_rg.name
  tags                = var.tags
}

data "azurerm_network_security_group" "nsg" {
  count               = var.nsg_name == null ? 0 : 1
  name                = var.nsg_name
  resource_group_name = local.network_rg.name
}

module "vnet" {
  source = "./modules/azurerm_vnet"

  name                = var.vnet_name
  prefix              = var.prefix
  resource_group_name = local.network_rg.name
  location            = var.location
  subnets             = local.subnets
  existing_subnets    = var.subnet_names
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_container_registry" "acr" {
  count                    = var.create_container_registry ? 1 : 0
  name                     = join("", regexall("[a-zA-Z0-9]+", "${var.prefix}acr")) # alpha numeric characters only are allowed
  resource_group_name      = local.aks_rg.name
  location                 = var.location
  sku                      = local.container_registry_sku
  admin_enabled            = var.container_registry_admin_enabled
  
  #
  # Moving from deprecated argument, georeplication_locations, but keeping container_registry_geo_replica_locs
  # for backwards compatability.
  #
  georeplications = (local.container_registry_sku == "Premium" && var.container_registry_geo_replica_locs != null) ? [
    for location_item in var.container_registry_geo_replica_locs:
      {
        location = location_item
        tags     = var.tags
      }
  ] : local.container_registry_sku == "Premium" ? [] : null

  tags                     = var.tags
}


resource "azurerm_network_security_rule" "acr" {
  name                        = "SAS-ACR"
  description                 = "Allow ACR from source"
  count                       = (length(local.acr_public_access_cidrs) != 0 && var.create_container_registry) ? 1 : 0
  priority                    = 180
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "5000"
  source_address_prefixes     = local.acr_public_access_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = local.nsg_rg_name
  network_security_group_name = local.nsg.name
}

module "aks" {
  source  = "Azure/aks/azurerm"
  version = "4.13.0"

  cluster_name                    = local.cluster_name
  resource_group_name             = local.aks_rg.name
  prefix                          = var.prefix
  agents_pool_name                = "system"
  enable_auto_scaling             = var.default_nodepool_min_nodes == var.default_nodepool_max_nodes ? false : true
  agents_count                    = var.default_nodepool_min_nodes == var.default_nodepool_max_nodes ? var.default_nodepool_min_nodes : null
  agents_min_count                = var.default_nodepool_min_nodes == var.default_nodepool_max_nodes ? null : var.default_nodepool_min_nodes
  agents_max_count                = var.default_nodepool_min_nodes == var.default_nodepool_max_nodes ? null : var.default_nodepool_max_nodes
  agents_max_pods                 = var.default_nodepool_max_pods
  os_disk_size_gb                 = var.default_nodepool_os_disk_size
  agents_size                     = var.default_nodepool_vm_type
  admin_username                  = var.node_vm_admin
  public_ssh_key                  = file(var.ssh_public_key)
  vnet_subnet_id                  = module.vnet.subnets["aks"].id
  kubernetes_version              = var.kubernetes_version
  orchestrator_version            = var.kubernetes_version
  agents_availability_zones       = var.default_nodepool_availability_zones
  enable_log_analytics_workspace  = var.create_aks_azure_monitor
  network_plugin                  = var.aks_network_plugin
  network_policy                  = var.aks_network_policy
  net_profile_dns_service_ip      = var.aks_dns_service_ip
  net_profile_docker_bridge_cidr  = var.aks_docker_bridge_cidr
  net_profile_outbound_type       = var.aks_outbound_type
  net_profile_pod_cidr            = var.aks_pod_cidr
  net_profile_service_cidr        = var.aks_service_cidr
  tags                            = var.tags
  user_assigned_identity_id       = local.aks_uai_id
  private_cluster_enabled         = local.is_private
  identity_type                   = var.aks_identity == "uai" ? "UserAssigned" : "SystemAssigned"
  client_id                       = local.aks_uai_id == null ? var.client_id : ""
  client_secret                   = local.aks_uai_id == null ? var.client_secret : ""
  # enable_role_based_access_control= false
  # rbac_aad_managed                = false
 
  depends_on                      = [module.vnet]

}

data "azurerm_kubernetes_cluster" "aks_cluster" {
  name                = local.cluster_name
  resource_group_name = local.aks_rg.name

  depends_on               = [ module.aks ]
}

data "dns_a_record_set" "aks_cluster_fqdn" {
  host = data.azurerm_kubernetes_cluster.aks_cluster.fqdn

  depends_on               = [ module.aks ]
}

module "kubeconfig" {
  source                   = "./modules/kubeconfig"
  prefix                   = var.prefix
  create_static_kubeconfig = var.create_static_kubeconfig
  path                     = local.kubeconfig_path
  namespace                = "kube-system"
  cluster_name             = local.cluster_name
  endpoint                 = module.aks.host
  ca_crt                   = module.aks.cluster_ca_certificate
  client_crt               = module.aks.client_certificate
  client_key               = module.aks.client_key
  token                    = module.aks.password
  depends_on               = [ module.aks ]
}

module "node_pools" {
  source = "./modules/aks_node_pool"

  for_each = var.node_pools

  node_pool_name = each.key
  aks_cluster_id = module.aks.aks_id
  vnet_subnet_id = module.vnet.subnets["aks"].id
  machine_type   = each.value.machine_type
  os_disk_size   = each.value.os_disk_size
  # TODO: enable with azurerm v2.37.0
  #  os_disk_type                 = each.value.os_disk_type
  enable_auto_scaling          = each.value.min_nodes == each.value.max_nodes ? false : true
  node_count                   = each.value.min_nodes
  min_nodes                    = each.value.min_nodes == each.value.max_nodes ? null : each.value.min_nodes
  max_nodes                    = each.value.min_nodes == each.value.max_nodes ? null : each.value.max_nodes
  max_pods                     = each.value.max_pods == null ? 110 : each.value.max_pods
  node_taints                  = each.value.node_taints
  node_labels                  = each.value.node_labels
  availability_zones           = (var.node_pools_availability_zone == "" || var.node_pools_proximity_placement == true) ? [] : [var.node_pools_availability_zone]
  proximity_placement_group_id = element(coalescelist(azurerm_proximity_placement_group.proximity.*.id, [""]), 0)
  orchestrator_version         = var.kubernetes_version
  tags                         = var.tags
}

# Module Registry - https://registry.terraform.io/modules/Azure/postgresql/azurerm/2.1.0
module "postgresql" {
  source  = "Azure/postgresql/azurerm"
  version = "2.1.0"

  for_each                     = local.postgres_servers != null ? length(local.postgres_servers) != 0 ? local.postgres_servers : {} : {}

  resource_group_name          = local.aks_rg.name
  location                     = var.location
  server_name                  = lower("${var.prefix}-${each.key}-pgsql")
  sku_name                     = each.value.sku_name
  storage_mb                   = each.value.storage_mb
  backup_retention_days        = each.value.backup_retention_days
  geo_redundant_backup_enabled = each.value.geo_redundant_backup_enabled
  administrator_login          = each.value.administrator_login
  administrator_password       = each.value.administrator_password
  server_version               = each.value.server_version
  ssl_enforcement_enabled      = each.value.ssl_enforcement_enabled
  firewall_rule_prefix         = "${var.prefix}-${each.key}-postgres-firewall-"
  firewall_rules               = local.postgres_firewall_rules
  vnet_rule_name_prefix        = "${var.prefix}-${each.key}-postgresql-vnet-rule-"
  postgresql_configurations    = each.value.postgresql_configurations
  tags                         = var.tags

  ## TODO : requires specific permissions
  vnet_rules = [{ name = "aks", subnet_id = module.vnet.subnets["aks"].id }, { name = "misc", subnet_id = module.vnet.subnets["misc"].id }]
}

module "netapp" {
  source        = "./modules/azurerm_netapp"
  count                = var.storage_type == "ha" ? 1 : 0

  prefix                = var.prefix
  resource_group_name   = local.aks_rg.name
  location              = var.location
  vnet_name             = module.vnet.name
  subnet_id             = module.vnet.subnets["netapp"].id
  service_level         = var.netapp_service_level
  size_in_tb            = var.netapp_size_in_tb
  protocols             = var.netapp_protocols
  volume_path           = "${var.prefix}-${var.netapp_volume_path}"
  tags                  = var.tags
  allowed_clients       = concat(module.vnet.subnets["aks"].address_prefixes, module.vnet.subnets["misc"].address_prefixes)
  depends_on            = [module.vnet]
}

data "external" "git_hash" {
  program = ["files/tools/iac_git_info.sh"]
}

data "external" "iac_tooling_version" {
  program = ["files/tools/iac_tooling_version.sh"]
}

resource "kubernetes_config_map" "sas_iac_buildinfo" {
  metadata {
     name      = "sas-iac-buildinfo"
     namespace = "kube-system"
  }

  data = {
     git-hash    = lookup(data.external.git_hash.result, "git-hash")
     iac-tooling = var.iac_tooling
     terraform   = <<EOT
version: ${lookup(data.external.iac_tooling_version.result, "terraform_version")}
revision: ${lookup(data.external.iac_tooling_version.result, "terraform_revision")}
provider-selections: ${lookup(data.external.iac_tooling_version.result, "provider_selections")}
outdated: ${lookup(data.external.iac_tooling_version.result, "terraform_outdated")}
EOT
  }

  depends_on = [ module.aks ]
}

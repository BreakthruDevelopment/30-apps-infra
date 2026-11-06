# Azure: each app runs on Container Apps (always-free grant) against one shared
# Postgres Flexible Server (B1ms, free for 12 months on a free account).

terraform {
  required_version = ">= 1.12"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.20, < 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # Filled in by -backend-config in CI (storage account, container, key).
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  # The bootstrap registered the providers this stack needs; don't try to register all of them.
  resource_provider_registrations = "none"
}

locals {
  catalog = yamldecode(file("${path.module}/../../apps.yaml")).apps
  apps    = { for a in local.catalog : a.name => a if contains(a.clouds, "azure") }
  tags    = { project = "30-apps-30-days", managed_by = "terraform" }
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "apps" {
  name     = "rg-30apps-apps"
  location = var.location
  tags     = local.tags
}

# --- Shared Postgres -----------------------------------------------------------

resource "random_password" "pg" {
  length  = 32
  special = false
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                          = "pg-30apps-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.apps.name
  location                      = var.pg_location
  version                       = "16"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true
  administrator_login           = "pgadmin"
  administrator_password        = random_password.pg.result
  tags                          = local.tags

  lifecycle {
    # Azure picks an availability zone at creation; don't fight it afterwards.
    ignore_changes = [zone]
  }
}

# Container Apps on the consumption plan have no fixed outbound IPs, so allow Azure-hosted
# clients. Connections still need the password and TLS (sslmode=require).
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  for_each  = local.apps
  name      = replace(each.key, "-", "_")
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# --- Container Apps ---------------------------------------------------------------

# No Log Analytics workspace: it bills per GB. Logs are still visible live in the portal.
resource "azurerm_container_app_environment" "main" {
  name                = "cae-30apps"
  resource_group_name = azurerm_resource_group.apps.name
  location            = azurerm_resource_group.apps.location
  tags                = local.tags
}

resource "random_password" "auth" {
  for_each = local.apps
  length   = 48
  special  = false
}

# Custom domains are not wired up on azure yet. Fail the plan loudly instead of promising a URL
# (APP_URL) whose DNS and certificate nobody creates. TODO: see README "Custom domains".
# Azure Container Apps (needs a CNAME, an asuid TXT record and a managed certificate).
resource "terraform_data" "domain_unsupported" {
  for_each = { for name, a in local.apps : name => a.domain if try(a.domain, null) != null }
  input    = each.value
  lifecycle {
    precondition {
      condition     = false
      error_message = "App ${each.key} sets domain ${each.value}, but custom domains are not supported on azure yet. Set domain: null for this cloud (see README, Custom domains)."
    }
  }
}

locals {
  app_url = {
    for name, a in local.apps : name => (
      try(a.domain, null) != null
      ? "https://${a.domain}"
      : "https://app-${name}.${azurerm_container_app_environment.main.default_domain}"
    )
  }
  database_url = {
    for name, a in local.apps : name => format(
      "postgres://pgadmin:%s@%s:5432/%s?sslmode=require",
      random_password.pg.result,
      azurerm_postgresql_flexible_server.main.fqdn,
      azurerm_postgresql_flexible_server_database.app[name].name,
    )
  }
}

resource "azurerm_container_app" "app" {
  for_each                     = local.apps
  name                         = "app-${each.key}"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.apps.name
  revision_mode                = "Single"
  tags                         = local.tags

  secret {
    name  = "database-url"
    value = local.database_url[each.key]
  }
  secret {
    name  = "auth-secret"
    value = random_password.auth[each.key].result
  }
  dynamic "secret" {
    for_each = toset(local.app_secret_names[each.key])
    content {
      # Container App secret names allow only lowercase letters, digits and hyphens.
      name  = "sec-${lower(replace(secret.value, "_", "-"))}"
      value = var.app_secrets[each.key][secret.value]
    }
  }
  dynamic "secret" {
    for_each = contains(local.gemini_apps, each.key) ? [1] : []
    content {
      name  = "gemini-api-key"
      value = var.gemini_api_key
    }
  }

  ingress {
    external_enabled = true
    target_port      = 3000
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = var.max_instances

    container {
      name   = "app"
      image  = "${each.value.image}:${each.value.tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }
      env {
        name        = "BETTER_AUTH_SECRET"
        secret_name = "auth-secret"
      }
      env {
        name  = "APP_URL"
        value = local.app_url[each.key]
      }
      env {
        name  = "APP_NAME"
        value = try(each.value.title, each.key)
      }
      env {
        name  = "APP_VERSION"
        value = each.value.tag
      }
      env {
        name  = "CLOUD"
        value = "azure"
      }
      env {
        name  = "MIGRATE_ON_START"
        value = "true"
      }
      env {
        name  = "AI_PROVIDER"
        value = local.ai_provider[each.key]
      }
      env {
        name  = "DB_POOL_MAX"
        value = "3"
      }
      dynamic "env" {
        for_each = toset(local.app_secret_names[each.key])
        content {
          name        = env.value
          secret_name = "sec-${lower(replace(env.value, "_", "-"))}"
        }
      }
      dynamic "env" {
        for_each = contains(local.gemini_apps, each.key) ? [1] : []
        content {
          name        = "GEMINI_API_KEY"
          secret_name = "gemini-api-key"
        }
      }
    }
  }
}

locals {
  # An app that asks for Gemini runs on demo answers until the key is configured; the app
  # refuses to start with AI_PROVIDER=gemini and no key.
  ai_provider = { for name, a in local.apps : name => (
    try(a.ai, "demo") == "gemini" && var.gemini_api_key == "" ? "demo" : try(a.ai, "demo")
  ) }
  gemini_apps = toset([for name, p in local.ai_provider : name if p == "gemini"])
}

locals {
  # Names (never values) of the secrets each app declared in apps.yaml and that were supplied.
  app_secret_names = { for name, a in local.apps : name => [
    for v in try(a.secrets, []) : v if contains(nonsensitive(keys(try(var.app_secrets[name], {}))), v)
  ] }
}

# Azure: each app runs on Container Apps (always-free grant) against one shared
# Postgres Flexible Server (B1ms, free for 12 months on a free account).

terraform {
  required_version = ">= 1.12"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.20, < 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
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

# azapi creates what azurerm cannot: the managed certificate and the SNI binding of a custom domain.
# It signs in like azurerm (ARM_* environment variables, OIDC in CI).
provider "azapi" {
  subscription_id = var.subscription_id
  # The bootstrap registered the providers this stack needs.
  skip_provider_registration = true
}

# DNS lives in Cloudflare. Only used when var.manage_dns is true (CI sets it when the
# CLOUDFLARE_API_TOKEN secret exists). Otherwise no cloudflare resource exists, so the placeholder is
# never sent anywhere. The real token comes from the CLOUDFLARE_API_TOKEN environment variable.
provider "cloudflare" {
  api_token = var.manage_dns ? null : "unused_dns_not_managed_00000000000000000" # 40 characters: the provider validates the format even when unused
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

# Allow-list Postgres extensions. Azure refuses CREATE EXTENSION for anything not listed in
# azure.extensions (a dynamic parameter, so no restart). This setting is a whole-list override: it
# replaces whatever is allow-listed today, so add new extensions to var.pg_allowed_extensions.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = upper(join(",", var.pg_allowed_extensions))
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

  # Azure adds the built-in "Consumption" workload profile on its own. Without this, every plan
  # proposes removing it in place, which we never want applied.
  lifecycle {
    ignore_changes = [workload_profile]
  }
}

resource "random_password" "auth" {
  for_each = local.apps
  length   = 48
  special  = false
}

# --- Custom domains (Cloudflare DNS + Azure managed certificate) -------------------------------
# For an app with a domain, one apply does, in this order:
#   1. Cloudflare: CNAME <domain> -> the app's default FQDN and TXT asuid.<domain> (DNS only).
#   2. azurerm_container_app_custom_domain: adds the hostname with binding Disabled. Azure checks the
#      records above, and a managed certificate can only be requested for a hostname the app already has.
#   3. azapi managed certificate (free, CNAME validation).
#   4. azapi_resource_action (HTTP PATCH): the app's ingress so the hostname uses the certificate (SniEnabled).
# Without manage_dns (no Cloudflare token) step 1 is skipped: the plan still works, but an apply would fail
# at step 2 until the records exist, so CI always passes the token on apply.

locals {
  domain_apps = { for name, a in local.apps : name => a.domain if try(a.domain, null) != null }
  # DNS records Terraform owns: only apps on azure in apps.yaml with a domain, and only with manage_dns.
  dns_apps = var.manage_dns ? local.domain_apps : {}
  zone_id  = var.cloudflare_zone_id != "" ? var.cloudflare_zone_id : try(data.cloudflare_zone.main[0].id, "")
}

data "cloudflare_zone" "main" {
  count = var.manage_dns && var.cloudflare_zone_id == "" ? 1 : 0
  # Needs Zone:Read on the token. With a DNS:Edit-only token set cloudflare_zone_id instead.
  filter = {
    name = var.dns_zone
  }
}

# Guard: Terraform may only create records under the app subdomains it is given; never the apex,
# mail, website or other existing names, and it never manages the zone itself.
resource "terraform_data" "dns_guard" {
  for_each = local.domain_apps
  input    = each.value

  # Without the Cloudflare token the DNS records can't be created, and Azure then refuses the custom
  # domain after the app has already switched APP_URL. Fail the plan instead of half-applying.
  lifecycle {
    precondition {
      condition     = var.manage_dns
      error_message = "App ${each.key} has domain ${each.value}, but no Cloudflare token reached this run (manage_dns is false). Add the CLOUDFLARE_API_TOKEN secret (and CLOUDFLARE_ZONE_ID variable) to the production environment, or set domain: null."
    }
    precondition {
      condition     = endswith(each.value, ".${var.dns_zone}") && !contains(var.reserved_hosts, trimsuffix(each.value, ".${var.dns_zone}")) && !startswith(each.value, "_")
      error_message = "App ${each.key}: domain ${each.value} must be a subdomain of ${var.dns_zone} that is not a reserved name (${join(", ", var.reserved_hosts)})."
    }
  }
}

resource "cloudflare_dns_record" "cname" {
  for_each = local.dns_apps
  zone_id  = local.zone_id
  name     = each.value
  type     = "CNAME"
  content  = azurerm_container_app.app[each.key].ingress[0].fqdn
  ttl      = 1
  proxied  = false
  comment  = "30-apps-infra: ${each.key} on Azure Container Apps"

  depends_on = [terraform_data.dns_guard]
}

# Proves to Azure that we own the domain. Quoted because Cloudflare stores TXT content with its quotes.
resource "cloudflare_dns_record" "asuid" {
  for_each = local.dns_apps
  zone_id  = local.zone_id
  name     = "asuid.${each.value}"
  type     = "TXT"
  content  = "\"${azurerm_container_app_environment.main.custom_domain_verification_id}\""
  ttl      = 1
  proxied  = false
  comment  = "30-apps-infra: ${each.key} Azure domain verification"

  depends_on = [terraform_data.dns_guard]
}

resource "azurerm_container_app_custom_domain" "app" {
  for_each         = local.domain_apps
  name             = each.value
  container_app_id = azurerm_container_app.app[each.key].id

  # The certificate and binding type are set by azapi_resource_action.binding below; without this
  # every plan would try to recreate the domain.
  lifecycle {
    ignore_changes = [certificate_binding_type, container_app_environment_certificate_id]
  }

  depends_on = [terraform_data.dns_guard, cloudflare_dns_record.cname, cloudflare_dns_record.asuid]
}

# Free Azure managed certificate. Created only after the hostname is on the app; validation follows
# the CNAME above. The create call returns once the certificate is issued.
resource "azapi_resource" "managed_cert" {
  for_each  = local.domain_apps
  type      = "Microsoft.App/managedEnvironments/managedCertificates@2024-03-01"
  name      = "cert-${each.key}"
  parent_id = azurerm_container_app_environment.main.id
  location  = azurerm_container_app_environment.main.location
  tags      = local.tags
  body = {
    properties = {
      subjectName             = each.value
      domainControlValidation = "CNAME"
    }
  }

  depends_on = [azurerm_container_app_custom_domain.app]
}

# Switch the hostname from Disabled to SniEnabled with the certificate, with a real HTTP PATCH (merge):
# only ingress.customDomains is sent, so the app's secrets and everything else stay as they are.
# (azapi_update_resource can't be used here: it GETs the app and PUTs it back, and a GET never returns
# secret values, so Azure rejects the PUT with ContainerAppSecretInvalid.) Re-runs only when the
# hostname or certificate changes; later azurerm updates (new image tag) read the app first and keep it.
resource "azapi_resource_action" "binding" {
  for_each    = local.domain_apps
  type        = "Microsoft.App/containerApps@2024-03-01"
  resource_id = azurerm_container_app.app[each.key].id
  method      = "PATCH"
  body = {
    properties = {
      configuration = {
        ingress = {
          customDomains = [{
            name          = each.value
            bindingType   = "SniEnabled"
            certificateId = azapi_resource.managed_cert[each.key].id
          }]
        }
      }
    }
  }

  depends_on = [azurerm_container_app_custom_domain.app]
}

locals {
  # APP_URL is what the app uses for sign-in cookies and origin checks. It is part of the container app
  # itself, which the domain resources depend on, so Terraform cannot wait for the binding: the app
  # gets the new URL in the same apply, a few minutes before the certificate is bound. The default URL
  # keeps serving throughout; only sign-in on it fails during that window.
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
  # Azure runs every app on the environment's built-in Consumption profile and reports it back;
  # leaving this null made each apply "change" it to null again.
  workload_profile_name = "Consumption"
  tags                  = local.tags

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

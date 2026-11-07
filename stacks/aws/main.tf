# AWS: each app runs on Lambda (the image includes the Lambda Web Adapter) behind an
# API Gateway HTTP API, with one shared RDS Postgres. This account's guardrails block
# GitHub's keyless sign-in, so this stack is applied from AWS CloudShell with deploy/aws.sh.
# Everything here is paid from the Free plan's credits; the Free plan can never bill a card.

terraform {
  required_version = ">= 1.12"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 8.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.25"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # Filled in by deploy/aws.sh (bucket, key, region).
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "30-apps-30-days", managed_by = "terraform" }
  }
}

# DNS lives in Cloudflare. Only used when var.manage_dns is true (deploy/aws.sh sets it when the
# token is in Parameter Store). Otherwise no cloudflare resource exists, so the placeholder is never
# sent anywhere. The real token comes from the CLOUDFLARE_API_TOKEN environment variable.
provider "cloudflare" {
  api_token = var.manage_dns ? null : "unused_dns_not_managed_00000000000000000" # 40 characters: the provider validates the format even when unused
}

locals {
  catalog = yamldecode(file("${path.module}/../../apps.yaml")).apps
  apps    = { for a in local.catalog : a.name => a if contains(a.clouds, "aws") }
}

# --- Images: one private ECR repository per app ----------------------------------------

resource "aws_ecr_repository" "app" {
  for_each             = local.apps
  name                 = "30apps/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the two newest images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 2 }
      action       = { type = "expire" }
    }]
  })
}

# --- Shared Postgres (RDS) -------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "postgres" {
  name        = "30apps-postgres"
  description = "Postgres for Lambda apps (Lambda outside a VPC has no fixed IPs; TLS and a 32-char password protect it)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Postgres over TLS"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "random_password" "pg" {
  length  = 32
  special = false
}

resource "aws_db_instance" "main" {
  identifier              = "apps30-postgres"
  engine                  = "postgres"
  engine_version          = "16"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  storage_type            = "gp3"
  username                = "pgadmin"
  password                = random_password.pg.result
  publicly_accessible     = true
  vpc_security_group_ids  = [aws_security_group.postgres.id]
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  lifecycle {
    ignore_changes = [engine_version] # minor upgrades are applied automatically
  }
}

provider "postgresql" {
  host      = aws_db_instance.main.address
  port      = 5432
  username  = "pgadmin"
  password  = random_password.pg.result
  sslmode   = "require"
  superuser = false
}

resource "postgresql_database" "app" {
  for_each = local.apps
  name     = replace(each.key, "-", "_")
}

# --- Lambda + API Gateway ----------------------------------------------------------------

resource "aws_iam_role" "lambda" {
  name = "30apps-lambda"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Created first and independently, so each function can know its own public URL.
resource "aws_apigatewayv2_api" "app" {
  for_each      = local.apps
  name          = "30apps-${each.key}"
  protocol_type = "HTTP"
}

resource "random_password" "auth" {
  for_each = local.apps
  length   = 48
  special  = false
}

locals {
  # Apps that asked for a custom domain.
  domain_apps = { for name, a in local.apps : name => a.domain if try(a.domain, null) != null }

  # Apps whose API Gateway custom domain and mapping exist after this apply.
  #  - manage_dns = true: all of them. Terraform creates the validation records in Cloudflare, waits for
  #    the certificate, then creates the domain, mapping and CNAME in one pass.
  #  - manage_dns = false (manual path): only those whose certificate ACM already reports ISSUED
  #    (deploy/aws.sh asks ACM and passes the list in), because the validation record is added by hand.
  # Until then APP_URL stays the execute-api URL, so cookies and sign-in keep working.
  mapped_apps = {
    for name, d in local.domain_apps : name => d
    if var.manage_dns || contains(var.issued_domains, d)
  }

  app_url = {
    for name, a in local.apps : name => (
      contains(keys(local.mapped_apps), name) ? "https://${local.mapped_apps[name]}" : aws_apigatewayv2_api.app[name].api_endpoint
    )
  }

  # DNS records Terraform owns: only for apps in apps.yaml with a domain, and only with manage_dns.
  dns_apps = var.manage_dns ? local.domain_apps : {}
  zone_id  = var.cloudflare_zone_id != "" ? var.cloudflare_zone_id : try(data.cloudflare_zone.main[0].id, "")
  validation = {
    for name in keys(local.dns_apps) : name => tolist(aws_acm_certificate.app[name].domain_validation_options)[0]
  }
}

# --- Custom domains ----------------------------------------------------------------------
# With manage_dns (the normal path) one apply does everything: certificate, its validation CNAME in
# Cloudflare, a wait for ISSUED, the API Gateway domain and mapping, and the app's own CNAME.
# Without it (no Cloudflare token) the certificate is created and its validation CNAME is printed
# for adding by hand; once ACM shows Issued, rerunning deploy/aws.sh creates the domain and mapping.

# Guard: Terraform may only create records under the app subdomains it is given. It never touches
# the apex, mail, website or other existing names in the zone, and it never manages the zone itself.
resource "terraform_data" "dns_guard" {
  for_each = local.dns_apps
  input    = each.value
  lifecycle {
    precondition {
      condition     = endswith(each.value, ".${var.dns_zone}") && !contains(var.reserved_hosts, trimsuffix(each.value, ".${var.dns_zone}")) && !startswith(each.value, "_")
      error_message = "App ${each.key}: domain ${each.value} must be a subdomain of ${var.dns_zone} that is not a reserved name (${join(", ", var.reserved_hosts)})."
    }
  }
}

data "cloudflare_zone" "main" {
  count = var.manage_dns && var.cloudflare_zone_id == "" ? 1 : 0
  # Needs Zone:Read on the token. With a DNS:Edit-only token set cloudflare_zone_id instead.
  filter = {
    name = var.dns_zone
  }
}

resource "aws_acm_certificate" "app" {
  for_each          = local.domain_apps
  domain_name       = each.value
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_dns_record" "acm_validation" {
  for_each = local.dns_apps
  zone_id  = local.zone_id
  name     = trimsuffix(local.validation[each.key].resource_record_name, ".")
  type     = local.validation[each.key].resource_record_type
  content  = trimsuffix(local.validation[each.key].resource_record_value, ".")
  ttl      = 1
  proxied  = false
  comment  = "30-apps-infra: ACM validation for ${each.key}"

  depends_on = [terraform_data.dns_guard]
}

resource "aws_acm_certificate_validation" "app" {
  for_each                = local.dns_apps
  certificate_arn         = aws_acm_certificate.app[each.key].arn
  validation_record_fqdns = [trimsuffix(local.validation[each.key].resource_record_name, ".")]

  timeouts {
    create = "15m"
  }

  depends_on = [cloudflare_dns_record.acm_validation]
}

resource "aws_apigatewayv2_domain_name" "app" {
  for_each    = local.mapped_apps
  domain_name = each.value

  domain_name_configuration {
    # With manage_dns, wait for the validation resource so the certificate is ISSUED first.
    certificate_arn = var.manage_dns ? aws_acm_certificate_validation.app[each.key].certificate_arn : aws_acm_certificate.app[each.key].arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "app" {
  for_each    = local.mapped_apps
  api_id      = aws_apigatewayv2_api.app[each.key].id
  domain_name = aws_apigatewayv2_domain_name.app[each.key].id
  stage       = aws_apigatewayv2_stage.app[each.key].id
}

resource "cloudflare_dns_record" "app" {
  for_each = local.dns_apps
  zone_id  = local.zone_id
  name     = each.value
  type     = "CNAME"
  content  = aws_apigatewayv2_domain_name.app[each.key].domain_name_configuration[0].target_domain_name
  ttl      = 1
  proxied  = false
  comment  = "30-apps-infra: ${each.key} on AWS"

  depends_on = [terraform_data.dns_guard, aws_apigatewayv2_api_mapping.app]
}

resource "aws_cloudwatch_log_group" "app" {
  for_each          = local.apps
  name              = "/aws/lambda/30apps-${each.key}"
  retention_in_days = 7
}

resource "aws_lambda_function" "app" {
  for_each      = local.apps
  function_name = "30apps-${each.key}"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.app[each.key].repository_url}:${each.value.tag}"
  architectures = ["arm64"]
  memory_size   = 1024
  timeout       = 29

  environment {
    variables = merge(contains(local.gemini_apps, each.key) ? { GEMINI_API_KEY = var.gemini_api_key } : {}, local.app_secret_env[each.key], {
      DATABASE_URL = format("postgres://pgadmin:%s@%s:5432/%s?sslmode=require",
      random_password.pg.result, aws_db_instance.main.address, postgresql_database.app[each.key].name)
      BETTER_AUTH_SECRET = random_password.auth[each.key].result
      APP_URL            = local.app_url[each.key]
      APP_NAME           = try(each.value.title, each.key)
      APP_VERSION        = each.value.tag
      CLOUD              = "aws"
      MIGRATE_ON_START   = "true"
      AI_PROVIDER        = local.ai_provider[each.key]
      DB_POOL_MAX        = "2"
      # Lambda Web Adapter: forward to the Next.js server on 3000; "/" is a static page,
      # so the function becomes ready even if the database is briefly unreachable.
      AWS_LWA_PORT                 = "3000"
      AWS_LWA_READINESS_CHECK_PATH = "/"
    })
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_logs, aws_cloudwatch_log_group.app]
}

resource "aws_apigatewayv2_integration" "app" {
  for_each               = local.apps
  api_id                 = aws_apigatewayv2_api.app[each.key].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.app[each.key].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "app" {
  for_each  = local.apps
  api_id    = aws_apigatewayv2_api.app[each.key].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.app[each.key].id}"
}

resource "aws_apigatewayv2_stage" "app" {
  for_each    = local.apps
  api_id      = aws_apigatewayv2_api.app[each.key].id
  name        = "$default"
  auto_deploy = true
  # Cap traffic so a burst can't run up Lambda and RDS usage.
  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_lambda_permission" "api" {
  for_each      = local.apps
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.app[each.key].execution_arn}/*"
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
  app_secret_env = { for name, vars in local.app_secret_names : name => { for v in vars : v => var.app_secrets[name][v] } }
}

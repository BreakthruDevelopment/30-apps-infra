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
  app_url = {
    for name, a in local.apps : name => (
      try(a.domain, null) != null ? "https://${a.domain}" : aws_apigatewayv2_api.app[name].api_endpoint
    )
  }
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
    variables = {
      DATABASE_URL = format("postgres://pgadmin:%s@%s:5432/%s?sslmode=require",
      random_password.pg.result, aws_db_instance.main.address, postgresql_database.app[each.key].name)
      BETTER_AUTH_SECRET = random_password.auth[each.key].result
      APP_URL            = local.app_url[each.key]
      APP_NAME           = try(each.value.title, each.key)
      APP_VERSION        = each.value.tag
      CLOUD              = "aws"
      MIGRATE_ON_START   = "true"
      AI_PROVIDER        = try(each.value.ai, "demo")
      DB_POOL_MAX        = "2"
      # Lambda Web Adapter: forward to the Next.js server on 3000; "/" is a static page,
      # so the function becomes ready even if the database is briefly unreachable.
      AWS_LWA_PORT                 = "3000"
      AWS_LWA_READINESS_CHECK_PATH = "/"
    }
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

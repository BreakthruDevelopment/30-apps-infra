# 30 Apps Infra

Deploys the **30 apps in 30 days** portfolio to AWS, Azure, Google Cloud and Oracle Cloud from one place.

App repos never hold cloud credentials: they build a container image and publish it to GitHub Container
Registry. This repo holds the Terraform and is the only repo the clouds trust, through GitHub's OpenID Connect
tokens (no stored keys on AWS, Azure or Google Cloud; a narrowly scoped key on Oracle, readable only by `main`).

| Who | Can do |
| --- | --- |
| Pull requests | `terraform plan` with read-only identities |
| `main`, via the `production` environment | `terraform apply` with deploy identities |

## One-time setup

1. In this repo: **Settings → Environments → New environment** `production`, then under *Deployment branches and
   tags* choose **Selected branches** and add `main`. This is what stops a pull request from deploying.
2. Run each cloud's bootstrap in that cloud's browser shell (already signed in), then add the values it prints as
   repository variables:

| Cloud | Shell | Command |
| --- | --- | --- |
| AWS | CloudShell | `curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/bootstrap/aws.sh \| bash` |
| Azure | Cloud Shell (Bash) | `curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/bootstrap/azure.sh \| bash` |
| Google Cloud | Cloud Shell | `curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/bootstrap/gcp.sh \| bash -s -- YOUR_PROJECT_ID` |
| Oracle Cloud | Cloud Shell | `curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/bootstrap/oci.sh \| bash` |

Each script is safe to rerun, prints exactly what it created, and creates nothing that costs money.

## How deploys work

`apps.yaml` lists every app, the clouds it runs on and the exact image tag. Changing it is how you deploy.

| Cloud | Runs on | Database | Deployed by |
| --- | --- | --- | --- |
| Azure | Container Apps (always-free grant) | Flexible Server B1ms (free 12 months) | GitHub Actions on merge to `main` |
| Google Cloud | Cloud Run in us-central1 (always-free) | Postgres on the always-free e2-micro, private network only | GitHub Actions on merge to `main` |
| Oracle Cloud | Docker + Caddy on the Always Free Ampere VM | Postgres on the same VM | GitHub Actions builds the VM once; an agent on the VM syncs with `apps.yaml` every 2 minutes |
| AWS | Lambda + API Gateway (us-east-2) | RDS db.t4g.micro (from Free plan credits) | One command in AWS CloudShell, below |

Every app is capped at one instance (`max_instances = 1`) so nothing grows past a free limit.

**AWS** (this account's guardrails block GitHub sign-in, and the Free plan is kept so it can never bill):

```
curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/deploy/aws.sh | bash
```

**Gemini key:** apps with `ai: gemini` get the key from the `GEMINI_API_KEY` secret in the `production`
environment (Azure, Google Cloud) or from AWS Parameter Store (`/30apps/gemini_api_key`, read by `deploy/aws.sh`).
Without a key they serve demo answers. The Oracle VM reads it from `/opt/30apps/env/shared.env`, which isn't
set up yet, so Oracle apps run on demo answers for now.

## Per-app secrets

An app that needs its own secrets (webhook secrets, ingest tokens) lists the **names** in `apps.yaml`; the
values never go in the repo:

```yaml
  - name: build-tracker
    secrets: [GITHUB_WEBHOOK_SECRET, INGEST_TOKEN, SYNC_TOKEN]
```

Each name becomes an environment variable of that name in the running app. A secret that has no value yet is
skipped with a warning that names it (never the value), so the deploy still goes through. Apps without
`secrets:` are unaffected. Generate each value with `openssl rand -hex 32` (64 characters; use at least 16).

| Cloud | Where the value lives | How to set it |
| --- | --- | --- |
| AWS | Parameter Store SecureString `/30apps/<name>/<VAR>`, read by `deploy/aws.sh` | In CloudShell, once per secret (the value is typed silently, so it doesn't show on screen or in history): |
| Azure, Google Cloud | Environment secret `<APPNAME>_<VAR>` in the `production` environment, read by the Apply job | **Settings → Environments → production → Add environment secret**. `APPNAME` is the app name upper-cased with `-` as `_`, e.g. `BUILD_TRACKER_INGEST_TOKEN` |
| Oracle | Not supported yet | The VM's agent doesn't read per-app secrets, so Oracle apps run without them |

```
read -rsp "Value: " V && echo && aws ssm put-parameter --region us-east-2 --name /30apps/<name>/<VAR> --type SecureString --overwrite --value "$V" --query Version --output text; unset V
```

Changing a value takes effect on the next deploy (merge to `main` for Azure and Google Cloud, rerun `deploy/aws.sh`
for AWS). Pull-request plans don't have the values, so a plan after secrets exist may show them as changing.
Terraform state holds the values like it holds the database password, in each cloud's private state bucket.

**Default URLs** until an app gets a custom domain: Azure `https://app-<name>.<env>.eastus.azurecontainerapps.io`,
Google Cloud `https://<name>-<project-number>.us-central1.run.app`, Oracle `https://<name>.<ip-with-dashes>.sslip.io`,
AWS `https://<id>.execute-api.us-east-2.amazonaws.com`. Each deploy prints them.

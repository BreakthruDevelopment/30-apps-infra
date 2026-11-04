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

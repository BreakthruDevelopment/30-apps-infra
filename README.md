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
| AWS, automatic deploys (after the first CloudShell deploy; see [below](#aws-automatic-deploys)) | CloudShell | `curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/bootstrap/aws-autodeploy.sh \| bash` |
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
| AWS | Lambda + API Gateway (us-east-2) | RDS db.t4g.micro (from Free plan credits) | A deployer Lambda inside the account pulls `main` every 10 minutes and deploys it ([AWS: automatic deploys](#aws-automatic-deploys)); one command in AWS CloudShell is the fallback |

Every app is capped at one instance (`max_instances = 1`) so nothing grows past a free limit.

**AWS** (this account's guardrails block GitHub sign-in, and the Free plan is kept so it can never bill).
Once automatic deploys are set up ([below](#aws-automatic-deploys)), merging to `main` deploys AWS by itself within
about 10 minutes. The manual fallback, which always works, in AWS CloudShell:

```
curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/deploy/aws.sh | bash
```

### AWS: automatic deploys

GitHub can't sign in to this AWS account, so instead of GitHub pushing, something inside AWS **pulls** (the same
idea as the Oracle VM's agent). Nothing in GitHub holds an AWS credential, and this repo being public is no risk.

```
EventBridge Scheduler (every 10 min) -> Lambda "apps30-deployer" (arm64 container image from ECR, 2 GB, 15 min)
  1. GitHub: what commit is main?  (read-only REST call, no sign-in)      same as /30apps/deployer/last_sha? stop.
  2. download that exact commit's tarball (by SHA), run ITS deploy/aws.sh  <- the same script CloudShell runs
  3. success: write last_sha.  Always: write last_result (JSON).           logs: CloudWatch, JSON lines
```

- **The deploy logic lives in this repo** (`deploy/aws.sh`), so a fix merged to `main` reaches AWS with no rebuild.
  The image (`deploy/lambda/`) only holds the tools (Terraform, crane, yq, AWS CLI), the Terraform providers
  (a filesystem mirror, so Lambda's small `/tmp` is enough) and the ~200-line runner `deploy/lambda/deployer.sh`.
  It is built by the **AWS deployer image** workflow and pushed to `ghcr.io/breakthrudevelopment/30apps-deployer`
  (public) only on `main`; pull requests build and smoke-test it without pushing. Lambda can only run ECR images, so
  the bootstrap copies it into ECR with crane.
- **What triggers a deploy:** any new commit on `main` (not only `apps.yaml`; a no-op Terraform run is harmless). A run
  that is already in progress is never overlapped: a Parameter Store lock (and reserved concurrency 1 where the account
  allows it). `deploy/aws.sh` takes the same lock when you run it in CloudShell. A commit that fails is retried at most
  3 times, 25+ minutes apart, then left alone until a new commit or a forced run, so a broken commit can't burn compute.
- **Where results are:** `aws ssm get-parameter --name /30apps/deployer/last_result` (sha, ok, time, message), or run
  `... | bash -s -- status`. The `urls`, health checks and DNS records print into the CloudWatch log group
  `/aws/lambda/apps30-deployer` (14 days). Terraform masks sensitive values and nothing prints a secret; secrets still
  live only in Parameter Store (`/30apps/...`, read by `deploy/aws.sh`) exactly as before.
- **IAM:** the function's role `apps30-deployer` has one inline policy scoped to this stack (state bucket, `30apps-*`
  Lambda/ECR/log names, API Gateway, RDS, security groups, ACM, Parameter Store `/30apps/*`, and IAM only for the one
  role `30apps-lambda` and only to attach the basic logging policy). It can't touch its own role or function. It is
  written in `bootstrap/aws-autodeploy.sh` (`write_policy`). If the policy ever misses an action, the deploy log shows the
  `AccessDenied`; `DEPLOYER_BROAD=1` on a bootstrap rerun adds the AWS-managed `PowerUserAccess` (what the old GitHub deploy
  role had).
- **Cost:** all within free tiers. Scheduler: ~4,300 invocations a month (14,000,000 free). Lambda: a no-change check is
  ~2 s at 2 GB (~4 GB-s, ~17,000 GB-s a month) and a typical deploy 3 to 8 minutes (~400 to 1,000 GB-s); 400,000 GB-s
  and 1,000,000 requests are free every month. The worst case, a commit that keeps failing, is capped at 3 runs of 15
  minutes (5,400 GB-s). ECR storage (~0.4 GB, two images kept) and CloudWatch Logs are negligible and come from Free plan
  credits like the rest.

**One-time setup**, after the first successful CloudShell deploy and once the *AWS deployer image* workflow has run on
`main`: (1) GitHub, Packages, `30apps-deployer`, Package settings, change visibility to **Public** (Lambda can only pull
through ECR, and the bootstrap copies it without credentials); (2) in AWS CloudShell:

```
curl -fsSL https://raw.githubusercontent.com/BreakthruDevelopment/30-apps-infra/main/bootstrap/aws-autodeploy.sh | bash
```

It is safe to rerun. It creates the roles, ECR repository, function and schedule, deploys once and prints the result. If
the account's guardrails refuse a step it says which and stops, leaving the CloudShell flow as it was. Afterwards, give
the script a command with `bash -s -- <command>`:

| Command | Does |
| --- | --- |
| *(none)* | Install or update. Rerun it to pick up a new deployer image (when `deploy/lambda/` or the provider constraints in `stacks/aws/main.tf` changed and the workflow pushed a new image) |
| `pause` / `resume` | Stop or restart the schedule. While paused, use the CloudShell one-liner |
| `deploy` | Deploy now even if `main` hasn't changed (also what to do after changing a Parameter Store secret), and print the result |
| `status` | Schedule, last deployed commit and result, lock, whether `main` moved |
| `remove` | Delete everything the script created (apps and Terraform state are untouched) |

Terraform and its providers are fixed in the image (Terraform pinned in `deploy/aws.sh` and the Dockerfile, which CI keeps equal, because Terraform won't read state written by a newer version; providers as resolved from the version constraints
in `stacks/aws/main.tf` when the image was built; the stack has no committed `.terraform.lock.hcl`). If a deploy fails with
a provider version error after a CloudShell run upgraded the providers, rerun the bootstrap after the image workflow has
rebuilt (run it from the Actions tab if `main.tf` didn't change).

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
| Azure, Google Cloud | Not wired yet (no app needs it). The stacks already accept them; see below | — |
| Oracle | Not supported yet | The VM's agent doesn't read per-app secrets, so Oracle apps run without them |

```
read -rsp "Value: " V && echo && aws ssm put-parameter --region us-east-2 --name /30apps/<name>/<VAR> --type SecureString --overwrite --value "$V" --query Version --output text; unset V
```

**Azure and Google Cloud, when an app first needs it.** Add the value as an environment secret named
`<APPNAME>_<VAR>` (app name upper-cased, `-` as `_`, e.g. `BUILD_TRACKER_INGEST_TOKEN`) under **Settings →
Environments → production**, then map that one secret explicitly in the cloud's Apply job and pass it to Terraform:

```yaml
      - name: Per-app secrets
        env:
          BUILD_TRACKER_INGEST_TOKEN: ${{ secrets.BUILD_TRACKER_INGEST_TOKEN }}
        run: |
          umask 077
          jq -n '{app_secrets: {"build-tracker": {INGEST_TOKEN: env.BUILD_TRACKER_INGEST_TOKEN}}}' > "$RUNNER_TEMP/app-secrets.tfvars.json"
      # then: terraform apply ... -var-file="$RUNNER_TEMP/app-secrets.tfvars.json", and rm the file in an always() step
```

Each secret is named one by one on purpose: handing the whole `secrets` context to a script would expose every
production secret (and GitHub flags such workflows as possibly malicious).

Changing a value takes effect on the next deploy (AWS: `bash -s -- deploy` of the autodeploy bootstrap, or rerun
`deploy/aws.sh` in CloudShell, because the deployer only reacts to new commits; merge to `main` for Azure and
Google Cloud once wired). Pull-request plans don't have the values, so a plan after secrets exist may show them as changing.
Terraform state holds the values like it holds the database password, in each cloud's private state bucket.

## Custom domains and DNS (Cloudflare)

DNS for `breakthruventures.ai` is hosted at Cloudflare (free plan). Deploys create each app's records
automatically, but **only** records for apps in `apps.yaml` that have a non-null `domain`. Terraform never
manages the zone itself and never imports, changes or deletes any other record: email (MX, SPF, DKIM,
autodiscover, imap, pop, smtp), the website (`@`, `www`), `dev`, `strategy`, `_lovable`, `_acme-challenge`,
`_dmarc.email` and the rest stay hand-managed. A guard fails the plan if an app's domain is not a subdomain of the
zone, starts with `_`, or is a reserved name (`www`, `dev`, `strategy`, `email`, `mail`, `autodiscover`, `imap`,
`pop`, `smtp`, ...; the `reserved_hosts` variable). If a record with the same name already exists, Cloudflare
refuses the create and the apply fails, so nothing is ever overwritten: delete a stale hand-made record first.
App records are always `proxied = false` (DNS only), TTL automatic.

### The Cloudflare token

Create one API token at Cloudflare: My Profile, API Tokens, Create Token, Custom token. Permission:
**Zone / DNS / Edit**; Zone Resources: Include, Specific zone, `breakthruventures.ai`. Nothing else.

| Where | Name | Used by |
| --- | --- | --- |
| AWS Parameter Store, SecureString | `/30apps/cloudflare/api_token` | `deploy/aws.sh` (exports `CLOUDFLARE_API_TOKEN`; never printed) |
| GitHub, Settings, Environments, `production`, secret | `CLOUDFLARE_API_TOKEN` | the Azure, Google Cloud and Oracle apply steps only (passed explicitly, not the whole `secrets` context) |

```
read -rsp "Token: " V && echo && aws ssm put-parameter --region us-east-2 --name /30apps/cloudflare/api_token --type SecureString --overwrite --value "$V" --query Version --output text; unset V
```

**Zone ID.** A DNS:Edit-only token cannot look the zone up by name (that needs Zone:Read). Give Terraform the zone
ID instead (not secret; Cloudflare, `breakthruventures.ai`, Overview, API section, Zone ID):
AWS: `aws ssm put-parameter --region us-east-2 --name /30apps/cloudflare/zone_id --type String --overwrite --value <zone id>`;
GitHub: repository variable `CLOUDFLARE_ZONE_ID`. If it is not set, Terraform looks the zone up by name, which works
only if the token also has Zone / Zone / Read.

Pull-request plans never get the token (a PR branch could print it). Terraform only uses Cloudflare when
`manage_dns` is true (`deploy/aws.sh` sets it when the SSM token exists; the Azure, Google Cloud and Oracle applies set it when
the secret exists), and with it false no Cloudflare resource or lookup exists. The Azure and Google Cloud PR plans set `manage_dns`
with a dummy token and skips the refresh (`-refresh=false`), so it lists the records an apply would create without
calling Cloudflare. Don't switch `manage_dns` back to false after records
were created: Terraform would plan to delete them and fail without a token. Remove an app's `domain` instead.

### AWS

An app with a `domain` gets an ACM certificate (DNS validation, us-east-2, free). With the token, one run of
`deploy/aws.sh` does it all: creates the validation CNAME in Cloudflare, waits (up to 15 minutes) for the certificate,
creates the API Gateway custom domain and mapping, creates the app's CNAME (`<host>` to the domain's
`target_domain_name`) and switches `APP_URL` to `https://<domain>`. At the end it prints the records, labelled as
created automatically. The `urls` output stays the `execute-api` URLs (the health check uses them); `custom_urls`
lists the custom ones that exist. Check `https://app1.breakthruventures.ai/api/health` after the run (DNS is usually
live within a minute).

**Manual fallback (no token in Parameter Store).** `deploy/aws.sh` says so and uses the old two-phase flow:

1. Run `deploy/aws.sh`. It prints a `PENDING` validation CNAME (host like `_3f2a....app1`, value like
   `_9b1c....acm-validations.aws`).
2. In Cloudflare, DNS, Records, Add record: type **CNAME**, name as printed (relative to the zone), target as
   printed, Proxy status **DNS only**, TTL Auto.
3. Wait until `aws acm list-certificates --region us-east-2 --query "CertificateSummaryList[].[DomainName,Status]" --output text`
   shows `ISSUED` (usually 5 to 30 minutes).
4. Rerun `deploy/aws.sh`. It creates the custom domain and mapping, updates `APP_URL`, and prints a `FINAL` record:
   CNAME, host `app1`, value `<id>.execute-api.us-east-2.amazonaws.com`. Add it the same way.

Leave the validation record in place; ACM uses it to renew the certificate. Anything configured with the old
`execute-api` URL (a GitHub webhook, the tracker's `TRACKER_URL`) keeps working, because that URL stays valid.

### Oracle Cloud

An OCI app with a `domain` gets an `A` record to the VM's public IP, created by the Oracle apply on merge to
`main` when the `CLOUDFLARE_API_TOKEN` secret exists. Caddy on the VM gets the certificate by itself once DNS
resolves. Without the token, add the `A` record by hand (the `public_ip` output has the address).

### Azure Postgres extensions

The shared Flexible Server allow-lists **pgvector** (`azure.extensions = VECTOR`, set in `stacks/azure/main.tf` from the
`pg_allowed_extensions` variable). Azure only lets `CREATE EXTENSION` run for allow-listed names. An app that needs
pgvector runs `CREATE EXTENSION IF NOT EXISTS vector` in its first migration (it migrates itself on startup).

To allow another extension, add its upper-case name to the `pg_allowed_extensions` default in
`stacks/azure/variables.tf` (keep `"VECTOR"` in the list; the setting replaces the whole list), open a PR and check
that the plan changes only `azurerm_postgresql_flexible_server_configuration.extensions`. `azure.extensions` is a
dynamic parameter, so applying it needs no server restart. Extensions that need `shared_preload_libraries` are a
different, static parameter and are not covered here. Confirm the installed pgvector version with
`SELECT default_version FROM pg_available_extensions WHERE name = 'vector'` (needs the live server).

### Azure

An Azure app with a `domain` gets, in one apply on merge to `main` (needs the `CLOUDFLARE_API_TOKEN` secret):

1. Cloudflare CNAME `<host>` to the container app's default hostname, and TXT `asuid.<host>` with the
   environment's domain verification ID (both DNS only).
2. `azurerm_container_app_custom_domain`, which adds the hostname with binding `Disabled` (Azure checks the records
   from step 1; a managed certificate can only be requested for a hostname the app already has).
3. A free Azure managed certificate (`azapi_resource`, `Microsoft.App/managedEnvironments/managedCertificates`,
   CNAME validation; azurerm cannot create one). The apply waits until it is issued, usually a few minutes.
4. `azapi_resource_action` sends an HTTP PATCH of only the app's ingress, binding the hostname to the certificate (`SniEnabled`). (A GET + PUT would fail: Azure never returns secret values.)

The custom domain resource ignores changes to its certificate and binding type (azapi owns them), so a second
apply plans no changes, and a new image tag keeps the binding. The deploy identity needs nothing new: Contributor on
the subscription covers managed certificates.

`APP_URL` becomes `https://<domain>` in the same apply. The app resource cannot wait for the binding that
depends on it, so for the few minutes before the certificate is bound, sign-in on the default URL fails (its Origin
check expects the custom URL); the default URL still serves pages. Without the token the plan still works and
warns that the DNS records are not planned; an apply would fail at step 2, so keep the secret set.

### Google Cloud

A Google Cloud app with a `domain` gets, in one apply on merge to `main` (needs the `CLOUDFLARE_API_TOKEN` secret):

1. `google_cloud_run_domain_mapping` (`certificate_mode = AUTOMATIC`) from the domain to the Cloud Run service.
   Domain mappings are **Preview** in Google Cloud (no SLA, and Google recommends a load balancer for production,
   which would cost money, so we do not use one). Mappings are free; Google issues and renews the certificate.
2. A Cloudflare CNAME `<host>` to `ghs.googlehosted.com` (taken from the mapping's `resource_records`), DNS only
   (`proxied = false`): Google must see its own host to issue the certificate.

**One-time, by hand:** the domain must be verified in Google Search Console (Domain property `breakthruventures.ai`,
TXT record at the apex, kept hand-managed in Cloudflare) and `gh-30apps-deploy@<project>.iam.gserviceaccount.com`
added as an **Owner** there, because Cloud Run requires the caller to be a verified owner. This covers every
subdomain, so it is done once.

**Certificate and `APP_URL`.** The certificate takes 15 minutes to 24 hours after the CNAME exists. Until then
`APP_URL` stays the run.app URL, so sign-in never breaks (the app checks the Origin against `APP_URL`).
Terraform switches `APP_URL` to `https://<domain>` only when the mapping's `Ready` condition is `True` in state:
rerun the workflow (**Actions, Terraform, Run workflow** on `main`) after the certificate is issued, and the refresh
sees it and updates the service. The `custom_domain_ready` output shows which apps have switched. The mapping names
the service as a plain string, so it never depends on the service (which reads the mapping's status): no cycle.
The service reads the mapping's status, so Terraform always creates the mapping before it creates or updates the service, and the mapping's service must already exist. Add a new app with `domain: null` first, and set `domain` in a later PR once its service is deployed.
If `Ready` is briefly not `True` (for example during certificate renewal), the next apply flips `APP_URL` back to the run.app URL until it is ready again.

An app's upload bucket (`storage: true`) allows CORS from the custom origin as well as run.app, from the first apply,
only for apps that have a `domain`. The `urls` output stays on run.app (the health check uses it);
`custom_urls` lists the custom ones. The pull-request plan uses a dummy token with `-refresh=false`, so it lists the
mapping and CNAME an apply would create without calling Cloudflare or Google's domain API. Without the real token an
apply fails at the plan stage with the guard's message.

**Default URLs** until an app gets a custom domain: Azure `https://app-<name>.<env>.eastus.azurecontainerapps.io`,
Google Cloud `https://<name>-<project-number>.us-central1.run.app`, Oracle `https://<name>.<ip-with-dashes>.sslip.io`,
AWS `https://<id>.execute-api.us-east-2.amazonaws.com`. Each deploy prints them.

## Object storage (Google Cloud)

An app opts in with `storage: true` in `apps.yaml` (only `gcp` honours it; other stacks ignore it). Terraform then
creates one private bucket per app, `<project-id>-<app>-uploads`, in the stack region (us-central1), and sets
`STORAGE_BUCKET` (and `UPLOAD_BUCKET`, same value) on the app's Cloud Run service.

| Setting | Value | Why |
| --- | --- | --- |
| Access | Uniform bucket-level access, public access prevention enforced | Nothing is ever public; reads and writes go through short-lived V4 signed URLs |
| Soft delete | Off (retention 0) | Soft-deleted bytes are billed |
| Versioning | Off | Noncurrent versions would be billed |
| Lifecycle | Delete after 90 days, objects under `u/` | Caps stored bytes |
| CORS | `PUT` only, from the app's origin(s) (run.app URL, plus `https://<domain>` when set); headers `Content-Type`, `x-goog-content-length-range` | Browser uploads straight to the bucket; downloads are plain navigation or `<img>` and need no CORS |
| Object access | `roles/storage.objectUser` for `cloud-run-apps` on that bucket only | No project-level storage role |
| Signing | The run service account signs through IAM `signBlob` as itself; no keys exist | Needs `roles/iam.serviceAccountTokenCreator` on itself |

**Free tier** (always-free, all buckets combined): 5 GB-months of regional storage in us-central1, us-east1 or
us-west1, 5,000 Class A and 50,000 Class B operations a month, 100 GB egress from North America. Terraform only
guarantees the region and storage class; operations are not metered here, so each app counts its own uploads and
reads against these numbers (see the app's spec).

**Bootstrap rights.** The deploy identity has Editor, which creates buckets and objects but cannot read or set IAM
policies. `bootstrap/gcp.sh` (rerun it once in Cloud Shell; it is idempotent) therefore adds:

- custom role `tf30appsBucketIam` (`storage.buckets.getIamPolicy`, `storage.buckets.setIamPolicy`) for `gh-30apps-deploy`,
  so Terraform can manage the bucket IAM member (narrower than `roles/storage.admin`);
- custom role `tf30appsBucketIamRead` (`storage.buckets.getIamPolicy`) for `gh-30apps-plan`, so pull-request plans can
  refresh bucket IAM;
- `roles/iam.serviceAccountTokenCreator` on `cloud-run-apps@<project>.iam.gserviceaccount.com`, granted to that same
  account (done in bootstrap because Terraform would need `iam.serviceAccounts.setIamPolicy`, i.e. service-account
  admin, to do it). If the account doesn't exist yet the script says so; rerun it after the first Google Cloud deploy.

It also enables `storage.googleapis.com`.

# The AWS "deployer": a Lambda function (custom runtime, container image, arm64) that deploys this repo's
# AWS stack from inside the account. See deploy/lambda/deployer.sh and the README ("AWS: automatic deploys").
#
# Build from the repository root:  docker build -f deploy/lambda/Dockerfile .
# The tools and the Terraform providers are baked in, so a run downloads nothing but the commit being deployed.
# Lambda's /tmp is only 512 MB and the AWS provider alone is several hundred MB, so the providers live in the
# image as an unpacked "filesystem mirror": `terraform init` links them instead of copying them into /tmp.
# Pinned by digest (the multi-arch index of public.ecr.aws/lambda/provided:al2023 when this was written); bump it on purpose.
FROM --platform=linux/arm64 public.ecr.aws/lambda/provided:al2023@sha256:b419ebba0f018a555467401d3e7eaafe3eb455a6a612ca06834887fdefde2621

# Tool versions. Terraform must equal TERRAFORM_VERSION in deploy/aws.sh (CI checks): the deployer and the CloudShell
# fallback then plan and write state identically, instead of differing by whatever "latest" was on the day.
# Terraform providers come from stacks/aws/.terraform.lock.hcl (committed), the same file CloudShell uses.
# crane and yq are pinned with their SHA-256 (arm64); Terraform is checked against HashiCorp's published SHA256SUMS.
ARG TERRAFORM_VERSION=1.17.1
ARG CRANE_VERSION=v0.20.3
ARG CRANE_SHA256=d2235f7779cd39c6e40f43701d2512c997409f629fb53e621ede0d57d3f995e2
ARG YQ_VERSION=v4.44.3
ARG YQ_SHA256=0e7e1524f68d91b3ff9b089872d185940ab0fa020a5a9052046ef10547023156

RUN dnf install -y jq tar gzip unzip findutils grep sed && dnf clean all \
 && command -v curl timeout bash

# AWS CLI v2 (aws.sh and the deployer use it for Parameter Store, ECR, ACM and STS). Latest at build time, over https.
RUN cd /tmp && curl --proto '=https' --proto-redir '=https' -fsSLo awscli.zip https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip \
 && unzip -q awscli.zip && ./aws/install && rm -rf awscli.zip aws /usr/local/aws-cli/v2/current/dist/awscli/examples

RUN set -eux; cd /tmp; \
    c='curl --proto =https --proto-redir =https -fsSL'; \
    $c -O "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_arm64.zip"; \
    $c -O "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"; \
    grep " terraform_${TERRAFORM_VERSION}_linux_arm64.zip\$" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q "terraform_${TERRAFORM_VERSION}_linux_arm64.zip" terraform -d /usr/local/bin; \
    $c -o crane.tgz "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_arm64.tar.gz"; \
    echo "${CRANE_SHA256}  crane.tgz" | sha256sum -c -; \
    tar -xzf crane.tgz -C /usr/local/bin crane; \
    $c -o /usr/local/bin/yq-go "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_arm64"; \
    echo "${YQ_SHA256}  /usr/local/bin/yq-go" | sha256sum -c -; \
    chmod +x /usr/local/bin/yq-go; \
    rm -f /tmp/*.zip /tmp/*.tgz /tmp/*SHA256SUMS

# Terraform providers, exactly the versions in the committed lock file, as an unpacked filesystem mirror.
COPY stacks/aws/main.tf stacks/aws/.terraform.lock.hcl /tmp/aws-stack/
RUN set -eux; cd /tmp/aws-stack; \
    terraform providers mirror -platform=linux_arm64 /tmp/mirror-packed; \
    cd /tmp/mirror-packed; \
    find . -name '*.zip' | while read -r z; do \
      dir="$(dirname "$z")"; base="$(basename "$z" .zip)"; \
      version="${base#terraform-provider-*_}"; version="${version%_linux_arm64}"; \
      mkdir -p "/opt/terraform/providers/${dir}/${version}/linux_arm64"; \
      unzip -q "$z" -d "/opt/terraform/providers/${dir}/${version}/linux_arm64"; \
    done; \
    find /opt/terraform/providers -type f -name 'terraform-provider-*' -exec chmod +x {} +; \
    cd /tmp/aws-stack; \
    for v in $(sed -n 's/^  version *= "\(.*\)"/\1/p' .terraform.lock.hcl); do \
      test -d "$(echo /opt/terraform/providers/*/*/*/"$v"/linux_arm64)" || { echo "mirror lacks locked provider version $v"; exit 1; }; \
    done; \
    test "$(find /opt/terraform/providers -mindepth 4 -maxdepth 4 -type d | wc -l)" = "$(grep -c '^provider ' .terraform.lock.hcl)"; \
    rm -rf /tmp/aws-stack /tmp/mirror-packed; \
    printf '%s\n' 'provider_installation {' '  filesystem_mirror {' '    path = "/opt/terraform/providers"' '  }' '}' > /opt/terraform/terraformrc; \
    find /opt/terraform/providers -maxdepth 4 -type d | sort

ENV TF_CLI_CONFIG_FILE=/opt/terraform/terraformrc \
    TF_IN_AUTOMATION=true \
    TF_INPUT=false \
    AWS_TARGET_REGION=us-east-2 \
    AWS_PAGER="" \
    AWS_EC2_METADATA_DISABLED=true

COPY deploy/lambda/bootstrap /var/runtime/bootstrap
COPY deploy/lambda/deployer.sh /var/task/deployer.sh
RUN chmod 755 /var/runtime/bootstrap /var/task/deployer.sh

LABEL org.opencontainers.image.source="https://github.com/BreakthruDevelopment/30-apps-infra" \
      org.opencontainers.image.description="Deploys the AWS stack of 30-apps-infra from inside the AWS account (pull model)"

# The runtime (bootstrap) calls handler() from deployer.sh.
CMD ["deployer.handler"]

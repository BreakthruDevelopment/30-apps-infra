# The AWS "deployer": a Lambda function (custom runtime, container image, arm64) that deploys this repo's
# AWS stack from inside the account. See deploy/lambda/deployer.sh and the README ("AWS: automatic deploys").
#
# Build from the repository root:  docker build -f deploy/lambda/Dockerfile .
# The tools and the Terraform providers are baked in, so a run downloads nothing but the commit being deployed.
# Lambda's /tmp is only 512 MB and the AWS provider alone is several hundred MB, so the providers live in the
# image as an unpacked "filesystem mirror": `terraform init` links them instead of copying them into /tmp.
FROM --platform=linux/arm64 public.ecr.aws/lambda/provided:al2023

# Versions of the tools. Terraform matches the CI's "^1.12.0" and the stack's "required_version >= 1.12".
# The providers are not pinned here: they are whatever stacks/aws/main.tf's version constraints resolve to
# when the image is built (the stack has no committed .terraform.lock.hcl). A change to main.tf rebuilds the image.
ARG TERRAFORM_VERSION=1.12.2
ARG CRANE_VERSION=v0.20.3
ARG YQ_VERSION=v4.44.3

RUN dnf install -y jq tar gzip unzip findutils grep sed && dnf clean all \
 && command -v curl timeout bash

# AWS CLI v2 (aws.sh and the deployer use it for Parameter Store, ECR, ACM and STS).
RUN cd /tmp && curl -fsSLo awscli.zip https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip \
 && unzip -q awscli.zip && ./aws/install && rm -rf awscli.zip aws /usr/local/aws-cli/v2/current/dist/awscli/examples

RUN set -eux; cd /tmp; \
    curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_arm64.zip"; \
    curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"; \
    grep " terraform_${TERRAFORM_VERSION}_linux_arm64.zip\$" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q "terraform_${TERRAFORM_VERSION}_linux_arm64.zip" terraform -d /usr/local/bin; \
    curl -fsSLO "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_arm64.tar.gz"; \
    curl -fsSLO "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/checksums.txt"; \
    grep " go-containerregistry_Linux_arm64.tar.gz\$" checksums.txt | sha256sum -c -; \
    tar -xzf go-containerregistry_Linux_arm64.tar.gz -C /usr/local/bin crane; \
    curl -fsSLo /usr/local/bin/yq-go "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_arm64"; \
    chmod +x /usr/local/bin/yq-go; \
    rm -f /tmp/*.zip /tmp/*.tar.gz /tmp/*SHA256SUMS /tmp/checksums.txt

# Terraform providers, resolved from the stack's own constraints, as an unpacked filesystem mirror.
COPY stacks/aws/main.tf /tmp/aws-stack/main.tf
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

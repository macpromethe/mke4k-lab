# ---------- STAGE 1: Builder ----------
FROM --platform=linux/amd64 ubuntu:22.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive
WORKDIR /build

ENV KUBECTL_VERSION=v1.32.5 \
    HELM_VERSION=v3.18.3 \
    TERRAFORM_VERSION=1.8.4 \
    K9S_VERSION=0.50.6 \
    YQ_VERSION=v4.45.1 \
    PATH=/usr/local/bin:$PATH

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        unzip \
        gnupg2 \
        ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    chmod +x kubectl

# Install helm
RUN curl -LO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" && \
    tar -xzf helm-${HELM_VERSION}-linux-amd64.tar.gz && \
    mv linux-amd64/helm helm && \
    chmod +x helm && \
    rm -rf helm-${HELM_VERSION}-linux-amd64.tar.gz linux-amd64

# Install terraform
RUN curl -LO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" && \
    unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
    chmod +x terraform && \
    rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip

# Install AWS CLI v2
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip

# Install k9s
RUN curl -fsSL "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
    -o k9s.tar.gz && \
    tar -xzf k9s.tar.gz k9s && \
    chmod +x k9s && \
    rm k9s.tar.gz

# Install yq
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    -o yq && \
    chmod +x yq

# ---------- STAGE 2: Runtime ----------
FROM --platform=linux/amd64 ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
WORKDIR /mke4k-lab

ENV HOME=/root \
    PATH=/usr/local/bin:$PATH

# Runtime packages (AWS-only: no Azure CLI, no OpenStack)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        unzip \
        gnupg2 \
        lsb-release \
        bash-completion \
        openssh-client \
        net-tools \
        iproute2 \
        iputils-ping \
        dnsutils \
        git \
        vim \
        jq \
        tmux \
        less \
        python3 && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Copy tools from builder
COPY --from=builder /build/kubectl         /usr/local/bin/kubectl
COPY --from=builder /build/helm            /usr/local/bin/helm
COPY --from=builder /build/terraform       /usr/local/bin/terraform
COPY --from=builder /build/k9s             /usr/local/bin/k9s
COPY --from=builder /build/yq              /usr/local/bin/yq
COPY --from=builder /usr/local/aws-cli     /usr/local/aws-cli

RUN ln -sf /usr/local/aws-cli/v2/current/bin/aws           /usr/local/bin/aws && \
    ln -sf /usr/local/aws-cli/v2/current/bin/aws_completer /usr/local/bin/aws_completer

# Copy project
COPY . /mke4k-lab

# Install t CLI
RUN ln -sf /mke4k-lab/bin/t-commandline.bash /usr/local/bin/t

# Set MOTD
RUN printf '\n  Welcome to mke4k-lab\n-------------------------------\n  Tools ready: terraform, kubectl, helm, aws, k9s\n  mkectl is downloaded on first use (version from config)\n  Edit /mke4k-lab/config then run: t deploy lab\n\n' \
    > /etc/motd

# Bash config (already landed via COPY . above; move to /root)
RUN mv /mke4k-lab/.bashrc /root/.bashrc

# Pre-initialise Terraform providers (speeds up first deploy)
RUN terraform -chdir=/mke4k-lab/terraform init -input=false && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENTRYPOINT ["/bin/bash"]

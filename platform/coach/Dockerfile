FROM mcr.microsoft.com/powershell:7.5-debian-12@sha256:7ab5bd5ca6f95a3351fa0c6a1205237d57048c94542355aab55519a0861a9b25

ARG KUBECTL_VERSION=v1.36.1
ARG KUBECTL_LINUX_SHA256=629d3f410e09bf49b64ae7079f7f0bda1191efed311f7d37fdbab0ad5b0ec2b7

ADD --checksum=sha256:${KUBECTL_LINUX_SHA256} \
    https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl \
    /usr/local/bin/kubectl

RUN chmod 0555 /usr/local/bin/kubectl \
    && useradd --uid 10001 --create-home --shell /bin/sh learner

USER 10001:10001
WORKDIR /workspace
ENV HOME=/tmp \
    KUBECONFIG=/run/learner/kubeconfig

CMD ["pwsh", "-NoLogo", "-NoProfile"]

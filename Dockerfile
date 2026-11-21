# Thin "SSH-ready" layer on top of an NVIDIA Dynamo nightly runtime image.
#
# BASE is the full, digest-pinned base reference, e.g.
#   nvcr.io/nvidia/ai-dynamo/vllm-runtime-nightly:20261117-7a70a51@sha256:...
# BASE_NAME / BASE_DIGEST only feed the OCI labels.
#
# Deliberately NOT changed: ENTRYPOINT, CMD, ENV, WORKDIR. They are inherited
# from the base untouched (the workflow's smoke test checks this).
ARG BASE
FROM ${BASE}

ARG BASE_NAME
ARG BASE_DIGEST
ARG SOURCE_URL=https://github.com/swhsiang/dynamo-pod-images

LABEL org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${BASE_NAME}" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}"

USER root

# ARG (not ENV) so it does not leak into the runtime environment.
ARG DEBIAN_FRONTEND=noninteractive

# - openssh-server: vllm/sglang have no OpenSSH, tensorrtllm only the client.
# - Host keys are removed: each pod generates its own (`ssh-keygen -A`) at start.
# - No authorized_keys is baked in; the pod start command adds $PUBLIC_KEY.
# - The drop-in is 00-* so it is read first; sshd keeps the first value it sees,
#   and Ubuntu's sshd_config Includes sshd_config.d/*.conf at the very top.
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /run/sshd /etc/ssh/sshd_config.d \
 && printf '%s\n' \
      '# Key-based auth only (dynamo-pod-images).' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin prohibit-password' \
      > /etc/ssh/sshd_config.d/00-dynamo-pod-hardening.conf \
 && chmod 644 /etc/ssh/sshd_config.d/00-dynamo-pod-hardening.conf

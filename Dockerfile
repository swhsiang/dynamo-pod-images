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

# Test tools for the dynamo-hunt pod driver, installed into the interpreter that
# imports Dynamo (the same search as the workflow's smoke check 8). Only what is
# missing is installed, so an image that already ships pytest keeps its version.
# - tensorrtllm: /opt/dynamo/venv has neither pytest nor pytest-timeout.
# - vllm, sglang: pytest present, pytest-timeout missing (probed 2026-11-22).
# The *_BREAK_SYSTEM_PACKAGES variables are set for this RUN only (not ENV, so
# Config.Env stays identical to the base): vllm's interpreter is /usr/bin/python3,
# which may carry a PEP 668 EXTERNALLY-MANAGED marker.
ARG PYTEST_VERSION=8.3.5
ARG PYTEST_TIMEOUT_VERSION=2.4.0
RUN set -eu; \
    py=""; \
    for p in python3 /opt/dynamo/venv/bin/python /opt/sglang/bin/python /opt/vllm/bin/python \
             /opt/*/bin/python3 /opt/*/*/bin/python3; do \
      if command -v "$p" >/dev/null 2>&1 && "$p" -c "import dynamo" 2>/dev/null; then \
        py=$(command -v "$p"); break; \
      fi; \
    done; \
    [ -n "$py" ] || { echo "no interpreter imports dynamo" >&2; exit 1; }; \
    want=""; \
    "$py" -c "import pytest" 2>/dev/null || want="pytest==${PYTEST_VERSION}"; \
    "$py" -c "import pytest_timeout" 2>/dev/null || want="$want pytest-timeout==${PYTEST_TIMEOUT_VERSION}"; \
    echo "dynamo interpreter: $py; installing: ${want:-nothing}"; \
    if [ -n "$want" ]; then \
      if "$py" -m pip --version >/dev/null 2>&1; then \
        PIP_BREAK_SYSTEM_PACKAGES=1 PIP_ROOT_USER_ACTION=ignore \
          "$py" -m pip install --no-cache-dir $want; \
      elif command -v uv >/dev/null 2>&1; then \
        UV_BREAK_SYSTEM_PACKAGES=1 uv pip install --no-cache --python "$py" $want; \
      else \
        echo "neither pip nor uv available for $py" >&2; exit 1; \
      fi; \
    fi; \
    "$py" -c "import pytest, pytest_timeout; print('pytest', pytest.__version__)"

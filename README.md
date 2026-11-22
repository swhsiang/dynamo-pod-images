# dynamo-pod-images

Thin "SSH-ready" images built on top of NVIDIA's Dynamo nightly runtime images, for use as
RunPod pod templates. The repo is public, and so far the GHCR packages are too (see Licence):

| framework | base (nvcr.io) | image (ghcr.io) |
|---|---|---|
| vllm | `nvidia/ai-dynamo/vllm-runtime-nightly:<tag>` | `ghcr.io/swhsiang/dynamo-vllm-ssh:<tag>` |
| sglang | `nvidia/ai-dynamo/sglang-runtime-nightly:<tag>` | `ghcr.io/swhsiang/dynamo-sglang-ssh:<tag>` |
| tensorrtllm | `nvidia/ai-dynamo/tensorrtllm-runtime-nightly:<tag>` | `ghcr.io/swhsiang/dynamo-tensorrtllm-ssh:<tag>` |

`<tag>` is the base's dated nightly tag (`YYYYMMDD-<shortsha>`). There is no `latest` tag.

## What the layer adds

The [Dockerfile](Dockerfile) adds only:

- `USER root` (the bases end with `USER dynamo`, which has no sudo).
- `openssh-server`, and `/run/sshd`.
- An sshd drop-in, `/etc/ssh/sshd_config.d/00-dynamo-pod-hardening.conf`: `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `PermitRootLogin prohibit-password`.
- No host keys (the package's keys are deleted; each pod runs `ssh-keygen -A` at start) and no
  `authorized_keys`.
- OCI labels `org.opencontainers.image.source`, `.base.name` (full base ref) and `.base.digest`
  (the base's linux/amd64 manifest digest; the build is pinned to exactly that digest).

ENTRYPOINT, CMD, ENV and WORKDIR are inherited unchanged; the smoke test checks this.

The pod's start command is expected to do (as root): `mkdir -p ~/.ssh /run/sshd`, append
`$PUBLIC_KEY` to `~/.ssh/authorized_keys`, `ssh-keygen -A`, write a filtered env to
`/etc/environment` (mode 600), then `exec /usr/sbin/sshd -D -e`.

## Building

Builds run only on GitHub-hosted runners (`ubuntu-24.04`, linux/amd64). Actions tab →
**build** → **Run workflow**, or:

```bash
gh workflow run build.yml -R swhsiang/dynamo-pod-images
```

Inputs:

- `nightly_tag`: empty (default) resolves the **newest dated tag present for every selected
  framework**, via the anonymous nvcr.io registry API (`/proxy_auth` token, then the paginated
  `/v2/<repo>/tags/list`). Using the newest tag common to all keeps the three images on the same
  Dynamo commit. Pass a tag to pin one, e.g. `-f nightly_tag=20261117-7a70a51`.
- `frameworks`: comma-separated subset, default `vllm,sglang,tensorrtllm`.

```bash
gh workflow run build.yml -R swhsiang/dynamo-pod-images -f nightly_tag=20261117-7a70a51 -f frameworks=vllm
```

Each matrix job: free disk → resolve base digest → pull → build → smoke test → push. The push
happens only if every smoke check passes. The job summary lists the digest, compressed size,
timings, free disk and the Dynamo interpreter path.

### Proposed schedule (not enabled)

To build automatically, add this under `on:` in the workflow:

```yaml
  schedule:
    - cron: "0 12 * * 1"   # Mondays 12:00 UTC; weekly keeps minutes and storage down
```

It's left off on purpose: each run pulls about 45 GB and pushes about as much, and every new tag
adds about 45 GB of storage (new nightlies share almost no layers with older ones).

## Disk: why the job deletes things

A standard runner has only about 14 GB free on `/`, and the tensorrtllm base is 18.3 GB
compressed and roughly 40-55 GB unpacked. Before pulling, the job:

1. Prints `df -h` ("BEFORE").
2. Turns off and deletes the swap file, prunes the preloaded Docker images and build cache, and
   deletes toolchains it never uses: .NET, Android SDK (the biggest), Haskell, Boost, Swift,
   Julia, all of `/opt/hostedtoolcache` (CodeQL included; no step uses it), PowerShell,
   Chromium and global node_modules.
3. Moves Docker's `data-root` to `/mnt/docker` if the runner's second disk on `/mnt` has more
   free space than `/` (it falls back to `/var/lib/docker` otherwise), and turns off the
   containerd snapshotter so that every layer is stored once, under `data-root`.
4. Prints `df -h` ("AFTER") and fails early if Docker's data-root has under 50 GB free
   (tensorrtllm) or 35 GB (the others).

It uses plain `docker build` (the default `docker` driver, layers stored once in the daemon) and
exports no build cache. A `docker-container` buildx builder would keep a second copy.

If tensorrtllm still doesn't fit, the job stops with the numbers. Larger runners cost extra and
aren't used.

## Cost notes

- **GHCR:** GitHub's billing docs currently say "Container image storage and bandwidth for the
  Container registry is currently free", with at least one month's notice before that changes.
  If it changes to the general GitHub Packages rates (from the pricing calculator: $0.25 per
  GB-month storage, $0.50 per GB transferred out of GitHub), about 45 GB comes to about $11/month
  per kept tag, and RunPod pulls count as transfer out. For example, 3 pulls a week of a 15 GB
  image is about 195 GB/month, or about $98. Delete old versions in the package settings to keep
  storage down.
- **Actions minutes:** this repo is public, so standard hosted runners are free and unmetered.
  One full run is 3 jobs; expect about 1-2 hours each, dominated by pull and push of the large
  images.
- **Pull from nvcr.io** is free and anonymous.

## Licence

This repository is public; it holds only the Dockerfile, workflow and docs, no NVIDIA content.
The images are a different matter: the bases are NVIDIA NGC containers, and NGC's container
licence may not permit public redistribution of derived images.

Packages pushed from this public repo came out **public** on GHCR, even though GitHub's docs
say new packages start private. The push step reports this as a warning and does not fail. If
you want them private, change each package's visibility in its settings (or delete it), and
make this repo private before rebuilding. A private package needs registry credentials to pull
(for example from RunPod): a GitHub token with only the `read:packages` scope. A public one
needs none.

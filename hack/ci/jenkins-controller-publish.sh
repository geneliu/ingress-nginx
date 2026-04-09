#!/usr/bin/env bash
# Internal patch pipeline: bug fixes and CVE-driven rebuilds only.
#
# Produces exactly two deliverables (same idea as .github/workflows/dockerhub-publish.yaml):
#   1) ingress-nginx controller container image: make build + make image + (optional) registry push
#   2) Helm chart packaged and (optional) pushed as OCI
#
# Local Mac (Podman): set RUNTIME=podman DOCKER=podman SKIP_PUSH=1 (see Makefile target local-patch-artifacts).
# On Apple Silicon, ARCH=arm64 avoids QEMU; use PLATFORM=linux/amd64 with Podman for amd64 images.
#
# Does not run full upstream release steps: no multi-arch `make release`, no controller-chroot image,
# no e2e or doc builds. Use upstream tooling separately if you need those.
#
# Intended for Jenkins agents or laptops with Docker or Podman, make, curl, Helm/yq (or script installs them), git.
#
# Required env (registry publish):
#   REGISTRY       Image registry prefix without trailing slash, e.g. registry.example.com/myorg
#   REGISTRY_USER  Registry username
#   REGISTRY_PASSWORD  Registry password or token (stdin to docker/helm login)
#
# Required env (local SKIP_PUSH=1): REGISTRY optional (default localhost/ingress for image name only).
#
# Optional env:
#   DOCKER         Container CLI (default docker). Use podman for Podman on Mac.
#   RUNTIME        For `make build` / run-in-docker.sh (default same as DOCKER).
#   SKIP_PUSH      If 1/true: no login, no image push, no helm registry push; chart tgz copied to dist/patch-artifacts/
#   CI_IMAGE_TAG   Force image tag (else TAG_NAME from Jenkins multibranch, else repo TAG file)
#   TAG_NAME       Set by Jenkins when building a tag (Multibranch)
#   ARCH           Default amd64 (use arm64 on Apple Silicon for native speed)
#   PATCH_ARTIFACT_DIR  Where to copy Helm tgz when SKIP_PUSH (default repo dist/patch-artifacts)
#   COMMIT_SHA     Default git-$(git rev-parse --short HEAD)
#   BUILD_ID       Default jenkins-${BUILD_NUMBER:-local}
#   SKIP_HELM      If 1, skip chart patch / package / helm push
#   SKIP_TRIVY     If 1, skip trivy image scan
#   HELM_VERSION   Helm version when curl-installing (default v3.16.2)
#   YQ_VERSION     yq version when curl-installing (default v4.45.1)
#
# HTTP(S) proxy (internal builds): HTTP_PROXY / HTTPS_PROXY / NO_PROXY (and lowercase forms).
# Note: docker pull/push need the *daemon* (or Podman machine) configured for proxy when required.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$ROOT"

truthy() { [[ "$1" == "1" || "$1" == "true" || "$1" == "yes" ]]; }

normalize_proxy_env() {
  if [[ -n "${HTTP_PROXY:-}" && -z "${http_proxy:-}" ]]; then export http_proxy="$HTTP_PROXY"; fi
  if [[ -n "${http_proxy:-}" && -z "${HTTP_PROXY:-}" ]]; then export HTTP_PROXY="$http_proxy"; fi
  if [[ -n "${HTTPS_PROXY:-}" && -z "${https_proxy:-}" ]]; then export https_proxy="$HTTPS_PROXY"; fi
  if [[ -n "${https_proxy:-}" && -z "${HTTPS_PROXY:-}" ]]; then export HTTPS_PROXY="$https_proxy"; fi
  if [[ -n "${ALL_PROXY:-}" && -z "${all_proxy:-}" ]]; then export all_proxy="$ALL_PROXY"; fi
  if [[ -n "${all_proxy:-}" && -z "${ALL_PROXY:-}" ]]; then export ALL_PROXY="$all_proxy"; fi
  if [[ -n "${NO_PROXY:-}" && -z "${no_proxy:-}" ]]; then export no_proxy="$NO_PROXY"; fi
  if [[ -n "${no_proxy:-}" && -z "${NO_PROXY:-}" ]]; then export NO_PROXY="$no_proxy"; fi
}
normalize_proxy_env

DOCKER="${DOCKER:-docker}"
export RUNTIME="${RUNTIME:-$DOCKER}"
export DOCKER
if [[ "$DOCKER" == "docker" ]]; then
  export DOCKER_BUILDKIT=1
fi

if [[ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}${http_proxy:-}${https_proxy:-}" ]]; then
  echo "Proxy enabled (HTTP_PROXY/HTTPS_PROXY or http_proxy/https_proxy set)"
fi

ARCH=${ARCH:-amd64}
HELM_VERSION=${HELM_VERSION:-v3.16.2}
YQ_VERSION=${YQ_VERSION:-v4.45.1}

if truthy "${SKIP_PUSH:-0}"; then
  REGISTRY="${REGISTRY:-localhost/ingress}"
  export BUILD_ID="${BUILD_ID:-local-$(id -un 2>/dev/null || echo user)}"
  REGISTRY_USER="${REGISTRY_USER:-}"
  REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-}"
else
  : "${REGISTRY:?REGISTRY is required (e.g. registry.example.com/myorg)}"
  : "${REGISTRY_USER:?REGISTRY_USER is required}"
  : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required}"
fi

resolve_image_tag() {
  if [[ -n "${CI_IMAGE_TAG:-}" ]]; then
    echo "$CI_IMAGE_TAG"
    return
  fi
  if [[ -n "${TAG_NAME:-}" ]]; then
    echo "$TAG_NAME"
    return
  fi
  if tag=$(git describe --tags --exact-match 2>/dev/null); then
    echo "$tag"
    return
  fi
  tr -d ' \n' < "$ROOT/TAG"
}

IMAGE_TAG=$(resolve_image_tag)
export COMMIT_SHA="${COMMIT_SHA:-git-$(git rev-parse --short HEAD)}"
export BUILD_ID="${BUILD_ID:-jenkins-${BUILD_NUMBER:-local}}"

REGISTRY_HOST=${REGISTRY%%/*}
REGISTRY_HELM_HOST=${REGISTRY_HELM_HOST:-$REGISTRY_HOST}
if [[ "$REGISTRY_HOST" == "docker.io" ]]; then
  REGISTRY_HELM_HOST=registry-1.docker.io
fi

echo "Using DOCKER=${DOCKER} RUNTIME=${RUNTIME} ARCH=${ARCH} IMAGE_TAG=${IMAGE_TAG} REGISTRY=${REGISTRY}"

download_yq() {
  local os arch yq_bin url
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) os=linux ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=amd64 ;;
    *) arch=amd64 ;;
  esac
  yq_bin="yq_${os}_${arch}"
  url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${yq_bin}"
  echo "Installing yq from ${url}"
  curl -fsSL -o /tmp/yq "$url"
  chmod +x /tmp/yq
  export PATH="/tmp:${PATH}"
}

download_helm() {
  local os arch base url
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) os=linux ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=amd64 ;;
    *) arch=amd64 ;;
  esac
  base="helm-${HELM_VERSION}-${os}-${arch}"
  url="https://get.helm.sh/${base}.tar.gz"
  echo "Installing helm from ${url}"
  curl -fsSL "$url" | tar -xz -C /tmp
  export PATH="/tmp/${os}-${arch}:${PATH}"
}

ensure_yq() {
  command -v yq >/dev/null 2>&1 && return
  download_yq
}

ensure_helm() {
  command -v helm >/dev/null 2>&1 && return
  download_helm
}

if ! truthy "${SKIP_PUSH:-0}"; then
  echo "$REGISTRY_PASSWORD" | "$DOCKER" login -u "$REGISTRY_USER" --password-stdin "$REGISTRY_HOST"
fi

make build ARCH="${ARCH}" TAG="${IMAGE_TAG}"
make image ARCH="${ARCH}" REGISTRY="${REGISTRY}" TAG="${IMAGE_TAG}"

if ! truthy "${SKIP_PUSH:-0}"; then
  "$DOCKER" push "${REGISTRY}/controller:${IMAGE_TAG}"
fi

if ! truthy "${SKIP_TRIVY:-0}" && command -v trivy >/dev/null 2>&1; then
  trivy image --exit-code 0 --severity CRITICAL,HIGH,MEDIUM,LOW,UNKNOWN \
    "${REGISTRY}/controller:${IMAGE_TAG}" || true
elif ! truthy "${SKIP_TRIVY:-0}"; then
  echo "trivy not on PATH; set SKIP_TRIVY=1 to silence or install trivy"
fi

if truthy "${SKIP_HELM:-0}"; then
  echo "SKIP_HELM=1; done."
  if truthy "${SKIP_PUSH:-0}"; then
    echo "Local image: ${REGISTRY}/controller:${IMAGE_TAG} (podman images | grep controller)"
  fi
  exit 0
fi

ensure_yq
ensure_helm

REPO="${REGISTRY}/controller"
VALUES="$ROOT/charts/ingress-nginx/values.yaml"
yq -i ".controller.image.repository = \"${REPO}\"" "$VALUES"
yq -i ".controller.image.tag = \"${IMAGE_TAG}\"" "$VALUES"
yq -i '.controller.image.digest = ""' "$VALUES"
yq -i '.controller.image.digestChroot = ""' "$VALUES"

CHART_OUT=$(mktemp -d)
trap 'rm -rf "$CHART_OUT"' EXIT
helm package "$ROOT/charts/ingress-nginx" --destination "$CHART_OUT"

if truthy "${SKIP_PUSH:-0}"; then
  ART_DIR="${PATCH_ARTIFACT_DIR:-$ROOT/dist/patch-artifacts}"
  mkdir -p "$ART_DIR"
  shopt -s nullglob
  for f in "$CHART_OUT"/ingress-nginx-*.tgz; do
    cp -f "$f" "$ART_DIR/"
    echo "Helm chart tarball: $ART_DIR/$(basename "$f")"
  done
  echo "Controller image (local): ${REGISTRY}/controller:${IMAGE_TAG}"
  echo "Tip: git checkout -- charts/ingress-nginx/values.yaml  # if you do not want chart edits committed"
  exit 0
fi

echo "$REGISTRY_PASSWORD" | helm registry login "$REGISTRY_HELM_HOST" \
  --username "$REGISTRY_USER" \
  --password-stdin

REGISTRY_PATH=$(echo "$REGISTRY" | cut -d/ -f2-)
HELM_OCI_BASE=${HELM_OCI_BASE:-oci://${REGISTRY_HELM_HOST}/${REGISTRY_PATH}}

shopt -s nullglob
for f in "$CHART_OUT"/ingress-nginx-*.tgz; do
  helm push "$f" "${HELM_OCI_BASE}"
done

echo "Published ${REGISTRY}/controller:${IMAGE_TAG} and Helm chart to ${HELM_OCI_BASE}"

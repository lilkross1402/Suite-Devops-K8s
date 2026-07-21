#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: utils/nexus_airgap_builder.sh
#
# PURPOSE : Air-Gap bundle builder using Sonatype Nexus 3.
#           Run this script on a BRIDGE MACHINE (internet + Docker access).
#           It will:
#             1. Boot a Nexus 3 container
#             2. Wait until Nexus API is healthy
#             3. Create a docker-hosted repository on port 5000
#             4. Pull every required image, retag it, and push to Nexus
#             5. Print the final transfer instructions
#
# USAGE   : sudo bash nexus_airgap_builder.sh [--k8s-version 1.29.3] [--skip-nexus]
#
# REQUIRES: docker, curl, jq
#
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# ANSI Colors (self-contained — does not depend on lib/logger.sh)
# ---------------------------------------------------------------------------
readonly _RED='\033[1;31m'
readonly _GRN='\033[1;32m'
readonly _YLW='\033[1;33m'
readonly _CYN='\033[1;36m'
readonly _WHT='\033[1;37m'
readonly _DIM='\033[2m'
readonly _RST='\033[0m'

_info()    { printf "${_CYN}[INFO]${_RST}  %b\n" "${*}"; }
_ok()      { printf "${_GRN}[  OK  ]${_RST} %b\n" "${*}"; }
_warn()    { printf "${_YLW}[ WARN ]${_RST} %b\n" "${*}" >&2; }
_error()   { printf "${_RED}[ERROR ]${_RST} %b\n" "${*}" >&2; }
_fatal()   { printf "\n${_RED}[ FATAL ]${_RST} %b\n\n" "${*}" >&2; exit 1; }
_section() { printf "\n${_WHT}━━━ %s ━━━${_RST}\n" "${*}"; }
_progress() {
    local current="${1}" total="${2}" label="${3}"
    local pct=$(( current * 100 / total ))
    local filled=$(( current * 40 / total ))
    local bar=""
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=filled; i<40; i++ )); do bar+="░"; done
    printf "\r  ${_CYN}[%3d%%]${_RST} ${bar} ${_DIM}%s${_RST}  " "${pct}" "${label}"
}

# ---------------------------------------------------------------------------
# Configuration (override via environment variables)
# ---------------------------------------------------------------------------
NEXUS_CONTAINER_NAME="${NEXUS_CONTAINER_NAME:-kubeops-nexus}"
NEXUS_DATA_DIR="${NEXUS_DATA_DIR:-/opt/nexus-data}"
NEXUS_UI_PORT="${NEXUS_UI_PORT:-8081}"
NEXUS_DOCKER_PORT="${NEXUS_DOCKER_PORT:-5000}"
NEXUS_ADMIN_PASS="${NEXUS_ADMIN_PASS:-}"
NEXUS_REPO_NAME="${NEXUS_REPO_NAME:-docker-airgap}"
NEXUS_LOCAL_REGISTRY="localhost:${NEXUS_DOCKER_PORT}"
NEXUS_IMAGE="${NEXUS_IMAGE:-sonatype/nexus3:latest}"

K8S_VERSION="${K8S_VERSION:-1.29.3}"
K8S_MINOR="${K8S_MINOR:-1.29}"

SKIP_NEXUS_SETUP="${SKIP_NEXUS_SETUP:-false}"
OUTPUT_BUNDLE_DIR="${OUTPUT_BUNDLE_DIR:-./nexus-airgap-bundle}"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --k8s-version)   K8S_VERSION="${2}"; K8S_MINOR="${2%.*}"; shift 2 ;;
            --nexus-pass)    NEXUS_ADMIN_PASS="${2}"; shift 2 ;;
            --nexus-port)    NEXUS_DOCKER_PORT="${2}"; NEXUS_LOCAL_REGISTRY="localhost:${2}"; shift 2 ;;
            --nexus-image)   NEXUS_IMAGE="${2}"; shift 2 ;;
            --output)        OUTPUT_BUNDLE_DIR="${2}"; shift 2 ;;
            --skip-nexus)    SKIP_NEXUS_SETUP="true"; shift ;;
            --help|-h)
                cat <<EOF
Usage: sudo bash nexus_airgap_builder.sh [OPTIONS]

OPTIONS:
  --k8s-version VERSION   Kubernetes version (default: ${K8S_VERSION})
  --nexus-pass PASSWORD   Nexus admin password (default: auto-detect)
  --nexus-port PORT       Nexus Docker registry port (default: ${NEXUS_DOCKER_PORT})
  --nexus-image IMAGE     Nexus Docker image (default: ${NEXUS_IMAGE})
  --output DIR            Bundle output directory (default: ${OUTPUT_BUNDLE_DIR})
  --skip-nexus            Skip Nexus boot/config (registry already running)
  --help                  Show this help
EOF
                exit 0 ;;
            *) _warn "Unknown argument: ${1}"; shift ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
_check_prerequisites() {
    _section "Prerequisites"
    local missing=()
    for cmd in docker curl jq; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        _fatal "Missing required tools: ${missing[*]}\nInstall with: apt-get install -y ${missing[*]}"
    fi
    if ! docker info &>/dev/null; then
        _fatal "Docker daemon is not running. Start with: systemctl start docker"
    fi
    _ok "All prerequisites satisfied (docker, curl, jq)"
}

# ---------------------------------------------------------------------------
# STEP 1 — Boot Nexus 3 container
# ---------------------------------------------------------------------------
_boot_nexus() {
    _section "Step 1/5 — Booting Sonatype Nexus 3"

    sudo mkdir -p "${NEXUS_DATA_DIR}"
    sudo chown -R 200:200 "${NEXUS_DATA_DIR}" 2>/dev/null || \
        sudo chmod -R 777 "${NEXUS_DATA_DIR}"

    if docker ps --format '{{.Names}}' | grep -q "^${NEXUS_CONTAINER_NAME}$"; then
        _ok "Nexus container already running — skipping boot"
        return 0
    fi

    if docker ps -a --format '{{.Names}}' | grep -q "^${NEXUS_CONTAINER_NAME}$"; then
        _info "Restarting existing Nexus container..."
        docker start "${NEXUS_CONTAINER_NAME}"
        return 0
    fi

    _info "Starting Nexus 3 container..."
    _info "  UI Port    : ${NEXUS_UI_PORT}   → http://localhost:${NEXUS_UI_PORT}"
    _info "  Docker Port: ${NEXUS_DOCKER_PORT} → http://localhost:${NEXUS_DOCKER_PORT}"
    _info "  Data Dir   : ${NEXUS_DATA_DIR}"

    docker run -d \
        --name "${NEXUS_CONTAINER_NAME}" \
        --restart unless-stopped \
        -p "${NEXUS_UI_PORT}:8081" \
        -p "${NEXUS_DOCKER_PORT}:${NEXUS_DOCKER_PORT}" \
        -v "${NEXUS_DATA_DIR}:/nexus-data" \
        "${NEXUS_IMAGE}"

    _ok "Nexus container started"
}

# ---------------------------------------------------------------------------
# STEP 2 — Wait for Nexus to be healthy
# ---------------------------------------------------------------------------
_wait_nexus_ready() {
    _section "Step 2/5 — Waiting for Nexus to become healthy"

    local max_wait=300
    local elapsed=0
    local interval=5

    _info "Polling http://localhost:${NEXUS_UI_PORT}/service/rest/v1/status"
    _info "(First boot may take 3-4 minutes — Nexus is unpacking...)"

    while true; do
        local status_code
        status_code=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://localhost:${NEXUS_UI_PORT}/service/rest/v1/status" 2>/dev/null || echo "000")

        if [[ "${status_code}" == "200" ]]; then
            printf "\n"
            _ok "Nexus is healthy (HTTP 200) after ${elapsed}s"
            break
        fi

        if [[ "${elapsed}" -ge "${max_wait}" ]]; then
            printf "\n"
            _fatal "Nexus did not become healthy within ${max_wait}s\nCheck: docker logs ${NEXUS_CONTAINER_NAME}"
        fi

        printf "\r  ${_DIM}[%3ds / %3ds]${_RST} Nexus starting... (HTTP %s) " \
            "${elapsed}" "${max_wait}" "${status_code}"
        sleep "${interval}"
        elapsed=$(( elapsed + interval ))
    done
}

# ---------------------------------------------------------------------------
# STEP 3 — Configure Nexus (repo + realms + anonymous access)
# ---------------------------------------------------------------------------
_configure_nexus() {
    _section "Step 3/5 — Configuring Nexus repository"

    # Retrieve auto-generated admin password
    if [[ -z "${NEXUS_ADMIN_PASS}" ]]; then
        _info "Retrieving auto-generated admin password..."
        local pass_file="${NEXUS_DATA_DIR}/admin.password"
        local retries=0
        while [[ ! -f "${pass_file}" && "${retries}" -lt 30 ]]; do
            sleep 2; retries=$(( retries + 1 ))
        done
        if [[ -f "${pass_file}" ]]; then
            NEXUS_ADMIN_PASS=$(cat "${pass_file}")
            _ok "Admin password retrieved"
        else
            _warn "admin.password not found — trying default 'admin123'"
            NEXUS_ADMIN_PASS="admin123"
        fi
    fi

    # Enable anonymous access
    _info "Enabling anonymous access (allow unauthenticated pulls)..."
    curl -s -u "admin:${NEXUS_ADMIN_PASS}" -X PUT \
        -H 'Content-Type: application/json' \
        "http://localhost:${NEXUS_UI_PORT}/service/rest/v1/security/anonymous" \
        -d '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' \
        > /dev/null 2>&1 || _warn "Anonymous access may already be configured"

    # Activate Docker Bearer Token realm
    _info "Activating Docker Bearer Token realm..."
    curl -s -u "admin:${NEXUS_ADMIN_PASS}" -X PUT \
        -H 'Content-Type: application/json' \
        "http://localhost:${NEXUS_UI_PORT}/service/rest/v1/security/realms/active" \
        -d '["NexusAuthenticatingRealm","NexusAuthorizingRealm","DockerToken"]' \
        > /dev/null 2>&1 || _warn "Docker realm activation may have failed"

    # Create docker-hosted repository
    local existing
    existing=$(curl -s -u "admin:${NEXUS_ADMIN_PASS}" \
        "http://localhost:${NEXUS_UI_PORT}/service/rest/v1/repositories" 2>/dev/null | \
        jq -r --arg name "${NEXUS_REPO_NAME}" '.[] | select(.name == $name) | .name' 2>/dev/null || echo "")

    if [[ -n "${existing}" ]]; then
        _ok "Repository '${NEXUS_REPO_NAME}' already exists"
    else
        _info "Creating docker-hosted repository '${NEXUS_REPO_NAME}' on port ${NEXUS_DOCKER_PORT}..."
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -u "admin:${NEXUS_ADMIN_PASS}" -X POST \
            -H 'Content-Type: application/json' \
            "http://localhost:${NEXUS_UI_PORT}/service/rest/v1/repositories/docker/hosted" \
            -d "{
              \"name\": \"${NEXUS_REPO_NAME}\",
              \"online\": true,
              \"storage\": {
                \"blobStoreName\": \"default\",
                \"strictContentTypeValidation\": true,
                \"writePolicy\": \"allow\"
              },
              \"docker\": {
                \"v1Enabled\": false,
                \"forceBasicAuth\": false,
                \"httpPort\": ${NEXUS_DOCKER_PORT}
              }
            }" 2>/dev/null)

        if [[ "${http_code}" =~ ^2 ]]; then
            _ok "Repository '${NEXUS_REPO_NAME}' created (HTTP ${http_code})"
        else
            _warn "Repository creation returned HTTP ${http_code} — may need manual verification"
        fi
    fi

    _info "Nexus UI        : http://localhost:${NEXUS_UI_PORT}"
    _info "Docker registry : http://localhost:${NEXUS_DOCKER_PORT}"
}

# ---------------------------------------------------------------------------
# Image manifest (all images needed for a production K8s cluster)
# ---------------------------------------------------------------------------
IMAGES_TO_PUSH=()

_build_image_list() {
    local k8s_patch="${K8S_VERSION}"

    # Use kubeadm if available for exact versions
    local k8s_images=()
    if command -v kubeadm &>/dev/null; then
        _info "Running 'kubeadm config images list' for K8s ${k8s_patch}..."
        mapfile -t k8s_images < <(kubeadm config images list \
            --kubernetes-version "${k8s_patch}" 2>/dev/null || true)
    fi

    # Hardcoded fallback for K8s 1.29
    if [[ ${#k8s_images[@]} -eq 0 ]]; then
        _info "Using hardcoded image list for K8s ${k8s_patch}"
        k8s_images=(
            "registry.k8s.io/kube-apiserver:v${k8s_patch}"
            "registry.k8s.io/kube-controller-manager:v${k8s_patch}"
            "registry.k8s.io/kube-scheduler:v${k8s_patch}"
            "registry.k8s.io/kube-proxy:v${k8s_patch}"
            "registry.k8s.io/pause:3.9"
            "registry.k8s.io/etcd:3.5.12-0"
            "registry.k8s.io/coredns/coredns:v1.11.1"
        )
    fi

    local cilium_images=(
        "quay.io/cilium/cilium:v1.15.1"
        "quay.io/cilium/operator-generic:v1.15.1"
        "quay.io/cilium/hubble-relay:v1.15.1"
        "quay.io/cilium/hubble-ui:v0.12.1"
        "quay.io/cilium/hubble-ui-backend:v0.12.1"
    )

    local calico_images=(
        "docker.io/calico/cni:v3.27.0"
        "docker.io/calico/node:v3.27.0"
        "docker.io/calico/kube-controllers:v3.27.0"
        "docker.io/calico/apiserver:v3.27.0"
        "docker.io/calico/pod2daemon-flexvol:v3.27.0"
    )

    local flannel_images=(
        "docker.io/flannel/flannel:v0.24.4"
        "docker.io/flannel/flannel-cni-plugin:v1.4.1-flannel1"
    )

    local monitoring_images=(
        "quay.io/prometheus/prometheus:v2.50.1"
        "quay.io/prometheus/alertmanager:v0.27.0"
        "quay.io/prometheus-operator/prometheus-operator:v0.72.0"
        "quay.io/prometheus-operator/prometheus-config-reloader:v0.72.0"
        "quay.io/kiwigrid/k8s-sidecar:1.26.1"
        "docker.io/grafana/grafana:10.4.0"
    )

    local kong_images=(
        "docker.io/kong/kong:3.6"
        "docker.io/kong/kubernetes-ingress-controller:3.1"
    )

    local redis_images=(
        "docker.io/bitnami/redis:7.2.4-debian-12-r9"
        "docker.io/bitnami/redis-exporter:1.58.0-debian-12-r1"
    )

    local infra_images=(
        "docker.io/library/registry:2"
    )

    IMAGES_TO_PUSH=(
        "${k8s_images[@]}"
        "${cilium_images[@]}"
        "${calico_images[@]}"
        "${flannel_images[@]}"
        "${monitoring_images[@]}"
        "${kong_images[@]}"
        "${redis_images[@]}"
        "${infra_images[@]}"
    )
}

# ---------------------------------------------------------------------------
# STEP 4 — Pull, retag, push
# ---------------------------------------------------------------------------
_push_images_to_nexus() {
    _section "Step 4/5 — Pulling and pushing images to Nexus"
    _build_image_list

    local total="${#IMAGES_TO_PUSH[@]}"
    local current=0
    local failed=()

    _info "Total images to process: ${_WHT}${total}${_RST}"
    printf "\n"

    for image in "${IMAGES_TO_PUSH[@]}"; do
        current=$(( current + 1 ))
        _progress "${current}" "${total}" "${image}"

        # Short name: "registry.k8s.io/kube-apiserver:v1.29.3" → "kube-apiserver:v1.29.3"
        local short_name="${image##*/}"
        local nexus_tag="${NEXUS_LOCAL_REGISTRY}/${short_name}"

        if ! docker pull "${image}" --quiet 2>/dev/null; then
            printf "\n"
            _warn "PULL FAILED: ${image}"
            failed+=("${image}")
            continue
        fi

        docker tag "${image}" "${nexus_tag}" 2>/dev/null

        if ! docker push "${nexus_tag}" --quiet 2>/dev/null; then
            printf "\n"
            _warn "PUSH FAILED: ${nexus_tag}"
            failed+=("${image}")
            continue
        fi

        docker rmi "${nexus_tag}" 2>/dev/null || true
    done

    printf "\n\n"

    if [[ ${#failed[@]} -gt 0 ]]; then
        _warn "${#failed[@]} image(s) failed:"
        for img in "${failed[@]}"; do
            printf "  ${_RED}✗${_RST} %s\n" "${img}"
        done
    else
        _ok "All ${total} images pushed to ${NEXUS_LOCAL_REGISTRY}"
    fi
}

# ---------------------------------------------------------------------------
# STEP 5 — Transfer instructions
# ---------------------------------------------------------------------------
_generate_transfer_instructions() {
    _section "Step 5/5 — Transfer Instructions"

    local nexus_host_ip
    nexus_host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "BRIDGE_IP")

    mkdir -p "${OUTPUT_BUNDLE_DIR}"

    # Environment file for KubeOps-Suite nodes
    cat > "${OUTPUT_BUNDLE_DIR}/kubeops-nexus.env" <<EOF
# KubeOps-Suite — Nexus Registry Configuration
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Source this on each K8s node or pass via --offline flag
export NEXUS_REGISTRY="${nexus_host_ip}:${NEXUS_DOCKER_PORT}"
export KUBEOPS_NETWORK_MODE="airgap"
export KUBEOPS_FORCE_OFFLINE="true"
EOF

    # Image manifest for audit
    printf "%s\n" "${IMAGES_TO_PUSH[@]}" > "${OUTPUT_BUNDLE_DIR}/image-manifest.txt"

    printf "\n"
    printf "  ${_WHT}┌─────────────────────────────────────────────────────────────┐${_RST}\n"
    printf "  ${_WHT}│  NEXUS AIR-GAP BUNDLE READY                                 │${_RST}\n"
    printf "  ${_WHT}└─────────────────────────────────────────────────────────────┘${_RST}\n\n"
    printf "  ${_CYN}Nexus UI        :${_RST}  http://${nexus_host_ip}:${NEXUS_UI_PORT}\n"
    printf "  ${_CYN}Docker Registry :${_RST}  http://${nexus_host_ip}:${NEXUS_DOCKER_PORT}\n"
    printf "  ${_CYN}Admin password  :${_RST}  ${NEXUS_ADMIN_PASS}\n\n"
    printf "  ${_WHT}ON EACH K8S NODE — Option A (KubeOps-Suite):${_RST}\n"
    printf "  ${_CYN}  sudo ./kubeops.sh --offline${_RST}\n"
    printf "  ${_DIM}  # Enter when prompted: ${nexus_host_ip}:${NEXUS_DOCKER_PORT}${_RST}\n\n"
    printf "  ${_WHT}ON EACH K8S NODE — Option B (manual env):${_RST}\n"
    printf "  ${_CYN}  source ${OUTPUT_BUNDLE_DIR}/kubeops-nexus.env${_RST}\n"
    printf "  ${_CYN}  sudo -E ./kubeops.sh --run containerd${_RST}\n\n"
    printf "  ${_DIM}Verify registry: curl -s http://${nexus_host_ip}:${NEXUS_DOCKER_PORT}/v2/_catalog | jq .${_RST}\n\n"

    _ok "Bundle written to: ${OUTPUT_BUNDLE_DIR}/"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
_print_banner() {
    printf "\n${_CYN}"
    cat <<'BANNER'
  ███╗   ██╗███████╗██╗  ██╗██╗   ██╗███████╗
  ████╗  ██║██╔════╝╚██╗██╔╝██║   ██║██╔════╝
  ██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║███████╗
  ██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║╚════██║
  ██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝███████║
  ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝
BANNER
    printf "${_RST}"
    printf "  ${_WHT}KubeOps-Suite :: Nexus Air-Gap Bundle Builder${_RST}\n"
    printf "  ${_DIM}K8s ${K8S_VERSION} | Nexus 3 | Docker Registry :${NEXUS_DOCKER_PORT}${_RST}\n\n"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    _parse_args "$@"
    _print_banner
    _check_prerequisites

    if [[ "${SKIP_NEXUS_SETUP}" != "true" ]]; then
        _boot_nexus
        _wait_nexus_ready
        _configure_nexus
    else
        _info "--skip-nexus: assuming Nexus is already running on localhost:${NEXUS_DOCKER_PORT}"
    fi

    _push_images_to_nexus
    _generate_transfer_instructions
}

main "$@"

#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: modules/01_registry.sh
# Purpose : Deploy a local Docker Registry v2 for Air-Gapped environments.
#           - Supports containerd and docker as container runtimes
#           - Configures TLS (self-signed) or plain HTTP mode
#           - Persists registry URL to state manager
#           - Loads seed images from offline-assets/
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SUITE_ROOT}/lib/logger.sh"
source "${SUITE_ROOT}/lib/os_detect.sh"
source "${SUITE_ROOT}/lib/network_check.sh"
source "${SUITE_ROOT}/lib/state_manager.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly REGISTRY_DATA_DIR="${REGISTRY_DATA_DIR:-/var/lib/kubeops-registry}"
readonly REGISTRY_PORT="${REGISTRY_PORT:-5000}"
readonly REGISTRY_NAME="${REGISTRY_NAME:-kubeops-registry}"
readonly REGISTRY_TLS_DIR="${REGISTRY_DATA_DIR}/certs"
readonly REGISTRY_AUTH_DIR="${REGISTRY_DATA_DIR}/auth"
readonly REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

_install_registry_docker() {
    local registry_ip="${1}"

    log_info "Deploying registry via Docker..."

    # Create data directories
    sudo mkdir -p "${REGISTRY_DATA_DIR}/data" "${REGISTRY_TLS_DIR}" "${REGISTRY_AUTH_DIR}"
    sudo chmod 700 "${REGISTRY_DATA_DIR}"

    # Generate self-signed TLS cert
    local use_tls=false
    if confirm "Use TLS (self-signed certificate)? Recommended for production"; then
        use_tls=true
        log_info "Generating self-signed TLS certificate for ${registry_ip}..."
        sudo openssl req -newkey rsa:4096 -nodes -sha256 \
            -keyout "${REGISTRY_TLS_DIR}/registry.key" \
            -x509 -days 365 \
            -out "${REGISTRY_TLS_DIR}/registry.crt" \
            -subj "/CN=${registry_ip}" \
            -addext "subjectAltName=IP:${registry_ip},DNS:${registry_ip},DNS:localhost" \
            2>/dev/null
        sudo chmod 600 "${REGISTRY_TLS_DIR}/registry.key"
        log_success "TLS certificate generated"

        # Trust self-signed cert
        _trust_registry_cert "${registry_ip}" "${REGISTRY_TLS_DIR}/registry.crt"
    fi

    # Remove existing registry container if present
    sudo docker rm -f "${REGISTRY_NAME}" 2>/dev/null || true

    if [[ "${use_tls}" == "true" ]]; then
        sudo docker run -d \
            --name "${REGISTRY_NAME}" \
            --restart=always \
            -p "${REGISTRY_PORT}:5000" \
            -v "${REGISTRY_DATA_DIR}/data:/var/lib/registry" \
            -v "${REGISTRY_TLS_DIR}:/certs" \
            -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
            -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
            -e REGISTRY_STORAGE_DELETE_ENABLED=true \
            "${REGISTRY_IMAGE}"
    else
        sudo docker run -d \
            --name "${REGISTRY_NAME}" \
            --restart=always \
            -p "${REGISTRY_PORT}:5000" \
            -v "${REGISTRY_DATA_DIR}/data:/var/lib/registry" \
            -e REGISTRY_STORAGE_DELETE_ENABLED=true \
            "${REGISTRY_IMAGE}"
    fi

    log_success "Registry container started: ${REGISTRY_NAME}"
}

_install_registry_containerd() {
    local registry_ip="${1}"

    log_info "Deploying registry via containerd (ctr)..."

    # Pull or import registry image
    local registry_tar
    registry_tar=$(find "${OFFLINE_ASSETS_DIR:-${SUITE_ROOT}/offline-assets}" \
        -name "registry*.tar" 2>/dev/null | head -1 || echo "")

    if [[ -n "${registry_tar}" ]]; then
        log_info "Loading registry image from: ${registry_tar}"
        sudo ctr images import "${registry_tar}" 2>/dev/null || \
            log_warn "Failed to import registry image"
    elif net_is_online; then
        log_info "Pulling registry image from Docker Hub..."
        sudo ctr images pull "docker.io/library/registry:2" 2>/dev/null || \
            log_warn "Failed to pull registry image"
    else
        log_error "No registry image found in offline-assets/ and network is unavailable"
        log_error "Add registry:2 tarball to ${SUITE_ROOT}/offline-assets/"
        return 1
    fi

    # Create data dir
    sudo mkdir -p "${REGISTRY_DATA_DIR}/data"
    sudo chmod 755 "${REGISTRY_DATA_DIR}"

    # Write registry config
    local reg_config="/tmp/kubeops-registry-config.yaml"
    cat > "${reg_config}" <<EOF
version: 0.1
log:
  fields:
    service: registry
storage:
  delete:
    enabled: true
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF

    # Create systemd service for registry via ctr
    sudo tee /etc/systemd/system/kubeops-registry.service > /dev/null <<EOF
[Unit]
Description=KubeOps Local Container Registry
After=containerd.service
Requires=containerd.service

[Service]
ExecStartPre=-/usr/local/bin/ctr task kill ${REGISTRY_NAME} 2>/dev/null
ExecStartPre=-/usr/local/bin/ctr containers rm ${REGISTRY_NAME} 2>/dev/null
ExecStart=/usr/local/bin/ctr run \\
    --rm \\
    --net-host \\
    --mount type=bind,src=${REGISTRY_DATA_DIR}/data,dst=/var/lib/registry,options=rbind:rw \\
    docker.io/library/registry:2 ${REGISTRY_NAME}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable kubeops-registry
    sudo systemctl start kubeops-registry
    log_success "Registry service started via containerd"
}

_trust_registry_cert() {
    local registry_ip="${1}"
    local cert_file="${2}"

    log_info "Trusting registry certificate..."

    case "${OS_FAMILY}" in
        debian)
            sudo cp "${cert_file}" "/usr/local/share/ca-certificates/kubeops-registry.crt"
            sudo update-ca-certificates 2>/dev/null || true
            ;;
        rhel)
            sudo cp "${cert_file}" "/etc/pki/ca-trust/source/anchors/kubeops-registry.crt"
            sudo update-ca-trust 2>/dev/null || true
            ;;
    esac

    # Configure containerd to trust
    local docker_cert_dir="/etc/docker/certs.d/${registry_ip}:${REGISTRY_PORT}"
    local containerd_cert_dir="${CONTAINERD_CONFIG_DIR:-/etc/containerd}/certs.d/${registry_ip}:${REGISTRY_PORT}"

    sudo mkdir -p "${docker_cert_dir}" "${containerd_cert_dir}"
    sudo cp "${cert_file}" "${docker_cert_dir}/ca.crt"
    sudo cp "${cert_file}" "${containerd_cert_dir}/ca.crt"

    log_success "Registry certificate trusted system-wide"
}

_seed_offline_images() {
    local registry_url="${1}"

    local seed_images
    mapfile -t seed_images < <(find "${SUITE_ROOT}/offline-assets" \
        -name "*.tar" -not -name "registry*.tar" 2>/dev/null | sort)

    if [[ ${#seed_images[@]} -eq 0 ]]; then
        log_info "No seed images found in offline-assets/ — skipping"
        return 0
    fi

    log_info "Seeding ${#seed_images[@]} image archive(s) into registry..."
    local count=0
    local total=${#seed_images[@]}

    for archive in "${seed_images[@]}"; do
        (( count++ )) || true
        log_progress_bar "${count}" "${total}" "Seeding images"
        local archive_name
        archive_name=$(basename "${archive}" .tar)

        if command -v skopeo &>/dev/null; then
            skopeo copy \
                "docker-archive:${archive}" \
                "docker://${registry_url}/${archive_name}:latest" \
                --dest-tls-verify=false 2>/dev/null || \
                log_warn "skopeo copy failed for ${archive_name}"
        elif command -v docker &>/dev/null; then
            sudo docker load < "${archive}" 2>/dev/null
            local image_tag
            image_tag=$(sudo docker load < "${archive}" 2>/dev/null | grep 'Loaded image' | awk '{print $NF}')
            if [[ -n "${image_tag}" ]]; then
                sudo docker tag "${image_tag}" "${registry_url}/${archive_name}:latest" 2>/dev/null || true
                sudo docker push "${registry_url}/${archive_name}:latest" 2>/dev/null || \
                    log_warn "Push failed for ${archive_name}"
            fi
        else
            log_warn "Neither skopeo nor docker available for image seeding"
            break
        fi
    done

    echo ""
    log_success "Image seeding complete"
}

_verify_registry() {
    local registry_url="${1}"

    log_info "Verifying registry at ${registry_url}..."
    sleep 3  # Give registry time to start

    local retries=5
    local wait=3
    for ((i=1; i<=retries; i++)); do
        if curl -s --connect-timeout 5 "http://${registry_url}/v2/" &>/dev/null || \
           curl -sk --connect-timeout 5 "https://${registry_url}/v2/" &>/dev/null; then
            log_success "Registry is UP and responding at ${registry_url}"

            # List repositories
            local catalog
            catalog=$(curl -s "http://${registry_url}/v2/_catalog" 2>/dev/null || \
                      curl -sk "https://${registry_url}/v2/_catalog" 2>/dev/null || echo '{"repositories":[]}')
            local repo_count
            repo_count=$(echo "${catalog}" | jq '.repositories | length' 2>/dev/null || echo "0")
            log_info "Registry catalog: ${repo_count} repository(ies)"
            return 0
        fi
        log_warn "Registry not ready (attempt ${i}/${retries}) — waiting ${wait}s..."
        sleep "${wait}"
    done

    log_error "Registry verification failed after ${retries} attempts"
    return 1
}

_print_registry_summary() {
    local registry_url="${1}"
    local registry_ip="${2}"

    log_section "🏭 Local Registry — Provisioning Complete"

    printf "\n  ${CLR_BOLD_WHITE}Registry Info:${CLR_RESET}\n"
    printf "  %-30s %s\n" "Registry URL:"     "${CLR_BOLD_GREEN}${registry_url}${CLR_RESET}"
    printf "  %-30s %s\n" "Data Directory:"   "${REGISTRY_DATA_DIR}/data"
    printf "  %-30s %s\n" "State File:"       "${KUBEOPS_STATE_FILE}"

    printf "\n  ${CLR_BOLD_WHITE}Usage Examples:${CLR_RESET}\n"
    printf "  ${CLR_DIM}# Push an image:${CLR_RESET}\n"
    printf "  ${CLR_YELLOW}docker tag myimage:latest %s/myimage:latest${CLR_RESET}\n" "${registry_url}"
    printf "  ${CLR_YELLOW}docker push %s/myimage:latest${CLR_RESET}\n\n" "${registry_url}"
    printf "  ${CLR_DIM}# List images:${CLR_RESET}\n"
    printf "  ${CLR_YELLOW}curl -s http://%s/v2/_catalog | jq .${CLR_RESET}\n\n" "${registry_url}"
    printf "  ${CLR_DIM}# Use in Pod spec:${CLR_RESET}\n"
    printf "  ${CLR_YELLOW}image: %s/myapp:v1.0${CLR_RESET}\n\n" "${registry_url}"
}

main() {
    log_banner
    log_section "Local Container Registry Provisioning"

    os_detect
    net_detect_mode

    local registry_ip
    registry_ip=$(net_get_primary_ip)

    printf "\n  ${CLR_BOLD_WHITE}Registry will be hosted at: ${CLR_BOLD_GREEN}%s:%s${CLR_RESET}\n\n" \
        "${registry_ip}" "${REGISTRY_PORT}"
    printf "  Override IP? [%s]: " "${registry_ip}"
    read -r input_ip
    if [[ -n "${input_ip}" ]]; then
        registry_ip="${input_ip}"
    fi

    local registry_url="${registry_ip}:${REGISTRY_PORT}"

    # Determine runtime
    local runtime="containerd"
    if command -v docker &>/dev/null && systemctl is-active docker &>/dev/null 2>&1; then
        runtime="docker"
    fi
    log_info "Using runtime: ${runtime}"

    if [[ "${runtime}" == "docker" ]]; then
        _install_registry_docker "${registry_ip}"
    else
        _install_registry_containerd "${registry_ip}"
    fi

    # Verify registry
    _verify_registry "${registry_url}"

    # Seed offline images if available
    if confirm "Seed offline image archives from offline-assets/ into registry?"; then
        _seed_offline_images "${registry_url}"
    fi

    # Save to state
    state_save_registry "${registry_ip}" "${REGISTRY_PORT}"

    _print_registry_summary "${registry_url}" "${registry_ip}"

    log_success "Registry provisioned and state saved"
    pause "Press [Enter] to return to main menu..."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_kong.sh
# Purpose : Deploy Kong API Gateway on Kubernetes via Helm or manifests.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

source "${SUITE_ROOT}/lib/logger.sh"
source "${SUITE_ROOT}/lib/network_check.sh"
source "${SUITE_ROOT}/lib/state_manager.sh"

readonly KONG_NS="kong"
readonly KONG_RELEASE="kong"

_deploy_kong_online() {
    log_info "Deploying Kong via Helm (ONLINE)..."

    helm repo add kong https://charts.konghq.com 2>/dev/null || true
    helm repo update

    helm upgrade --install "${KONG_RELEASE}" kong/kong \
        --namespace "${KONG_NS}" \
        --create-namespace \
        --set ingressController.installCRDs=true \
        --set proxy.type=NodePort \
        --set proxy.http.nodePort=32080 \
        --set proxy.tls.nodePort=32443 \
        --set admin.enabled=true \
        --set admin.type=NodePort \
        --set admin.http.nodePort=32001 \
        --set admin.tls.enabled=false \
        --set manager.enabled=true \
        --set manager.type=NodePort \
        --set manager.http.nodePort=32002 \
        --set postgresql.enabled=false \
        --set env.database=off \
        --wait --timeout=10m

    log_success "Kong API Gateway deployed"
}

_deploy_kong_airgap() {
    log_info "Deploying Kong from offline assets (AIR-GAP)..."

    local manifest
    manifest=$(find "${SUITE_ROOT}/offline-assets" \
        -name "kong-*.yaml" 2>/dev/null | head -1 || echo "")

    local registry_url
    registry_url=$(state_get ".registry.url" 2>/dev/null || echo "")

    if [[ -n "${manifest}" ]]; then
        if [[ -n "${registry_url}" ]]; then
            sed "s|docker.io|${registry_url}|g" "${manifest}" | kubectl apply -n "${KONG_NS}" -f -
        else
            kubectl apply -n "${KONG_NS}" -f "${manifest}"
        fi
        log_success "Kong deployed from offline manifest"
    else
        log_warn "No Kong manifest found — add kong-*.yaml to offline-assets/"
    fi
}

_print_summary() {
    local node_ip
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "MASTER_IP")

    log_section "🦍 Kong API Gateway — Deployed"
    printf "\n  ${CLR_BOLD_WHITE}Endpoints:${CLR_RESET}\n"
    printf "  %-28s ${CLR_BOLD_GREEN}http://%s:32080${CLR_RESET}\n"  "Proxy (HTTP):"  "${node_ip}"
    printf "  %-28s ${CLR_BOLD_GREEN}https://%s:32443${CLR_RESET}\n" "Proxy (HTTPS):" "${node_ip}"
    printf "  %-28s ${CLR_BOLD_CYAN}http://%s:32001${CLR_RESET}\n"   "Admin API:"     "${node_ip}"
    printf "  %-28s ${CLR_BOLD_CYAN}http://%s:32002${CLR_RESET}\n"   "Kong Manager:"  "${node_ip}"
    printf "\n  ${CLR_YELLOW}kubectl get pods -n %s${CLR_RESET}\n\n" "${KONG_NS}"
}

main() {
    log_banner
    log_section "Deploying Kong API Gateway"

    net_detect_mode

    if ! state_is_cluster_initialized; then
        log_fatal "No cluster found. Initialize the master first."
    fi

    local kubeconfig="${HOME}/.kube/config"
    [[ ! -f "${kubeconfig}" ]] && kubeconfig="/etc/kubernetes/admin.conf"
    export KUBECONFIG="${kubeconfig}"

    kubectl create namespace "${KONG_NS}" --dry-run=client -o yaml | \
        kubectl apply -f - 2>/dev/null || true

    if net_is_online && command -v helm &>/dev/null; then
        _deploy_kong_online
    else
        _deploy_kong_airgap
    fi

    _print_summary

    log_success "Kong deployment complete"
    pause "Press [Enter] to return to main menu..."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_monitoring.sh
# Purpose : Deploy Prometheus + Grafana observability stack via Helm
#           or plain manifests (air-gap mode).
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SUITE_ROOT}/lib/logger.sh"
source "${SUITE_ROOT}/lib/network_check.sh"
source "${SUITE_ROOT}/lib/state_manager.sh"

readonly MONITORING_NS="monitoring"
readonly PROMETHEUS_RELEASE="prometheus-stack"

_ensure_namespace() {
    local ns="${1}"
    kubectl create namespace "${ns}" --dry-run=client -o yaml | \
        kubectl apply -f - 2>/dev/null || true
    log_success "Namespace ready: ${ns}"
}

_install_helm() {
    if command -v helm &>/dev/null; then
        log_info "Helm already installed: $(helm version --short 2>/dev/null)"
        return 0
    fi

    log_info "Installing Helm..."
    if net_is_online; then
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    else
        local helm_bin
        helm_bin=$(find "${SUITE_ROOT}/offline-assets" -name "helm" -type f 2>/dev/null | head -1 || echo "")
        if [[ -n "${helm_bin}" ]]; then
            sudo install -m 755 "${helm_bin}" /usr/local/bin/helm
        else
            log_warn "Helm binary not found in offline-assets — using kubectl manifests"
            return 1
        fi
    fi
    log_success "Helm installed"
}

_deploy_online() {
    log_info "Deploying kube-prometheus-stack via Helm (ONLINE mode)..."

    helm repo add prometheus-community \
        https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update

    local registry_url
    registry_url=$(state_get ".registry.url" 2>/dev/null || echo "")

    helm upgrade --install "${PROMETHEUS_RELEASE}" \
        prometheus-community/kube-prometheus-stack \
        --namespace "${MONITORING_NS}" \
        --create-namespace \
        --set prometheus.prometheusSpec.retention=30d \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi \
        --set grafana.adminPassword="$(openssl rand -base64 16)" \
        --set grafana.service.type=NodePort \
        --set grafana.service.nodePort=32000 \
        --set alertmanager.enabled=true \
        --wait --timeout=10m

    log_success "kube-prometheus-stack deployed"
}

_deploy_airgap() {
    log_info "Deploying monitoring stack from offline manifests (AIR-GAP mode)..."

    local manifest
    manifest=$(find "${SUITE_ROOT}/offline-assets" \
        -name "prometheus-*.yaml" -o -name "monitoring-*.yaml" 2>/dev/null | head -1 || echo "")

    local registry_url
    registry_url=$(state_get ".registry.url" 2>/dev/null || echo "")

    if [[ -n "${manifest}" ]]; then
        if [[ -n "${registry_url}" ]]; then
            sed "s|docker.io|${registry_url}|g; s|quay.io|${registry_url}|g" \
                "${manifest}" | kubectl apply -n "${MONITORING_NS}" -f -
        else
            kubectl apply -n "${MONITORING_NS}" -f "${manifest}"
        fi
        log_success "Monitoring deployed from offline manifest"
    else
        log_warn "No monitoring manifest found in offline-assets/"
        log_warn "Add prometheus-stack manifests to ${SUITE_ROOT}/offline-assets/"
    fi
}

_print_summary() {
    log_section "📊 Observability Stack — Deployed"

    local grafana_node
    grafana_node=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "MASTER_IP")

    printf "\n  ${CLR_BOLD_WHITE}Access URLs:${CLR_RESET}\n"
    printf "  %-28s ${CLR_BOLD_GREEN}http://%s:32000${CLR_RESET}\n" "Grafana:" "${grafana_node}"
    printf "  %-28s %s\n" "Default User:" "admin"
    printf "  %-28s %s\n" "Password:" "(stored in grafana secret)"

    printf "\n  ${CLR_YELLOW}kubectl get secret -n %s %s-grafana -o jsonpath='{.data.admin-password}' | base64 -d${CLR_RESET}\n\n" \
        "${MONITORING_NS}" "${PROMETHEUS_RELEASE}"

    printf "  ${CLR_BOLD_WHITE}Check Status:${CLR_RESET}\n"
    printf "  ${CLR_YELLOW}kubectl get pods -n %s${CLR_RESET}\n\n" "${MONITORING_NS}"
}

main() {
    log_banner
    log_section "Deploying Observability Stack (Prometheus + Grafana)"

    net_detect_mode

    if ! state_is_cluster_initialized; then
        log_fatal "No cluster found. Initialize the master first."
    fi

    local kubeconfig="${HOME}/.kube/config"
    [[ ! -f "${kubeconfig}" ]] && kubeconfig="/etc/kubernetes/admin.conf"
    export KUBECONFIG="${kubeconfig}"

    _ensure_namespace "${MONITORING_NS}"

    if _install_helm 2>/dev/null; then
        if net_is_online; then
            _deploy_online
        else
            _deploy_airgap
        fi
    else
        _deploy_airgap
    fi

    _print_summary

    log_success "Monitoring stack deployed"
    pause "Press [Enter] to return to main menu..."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

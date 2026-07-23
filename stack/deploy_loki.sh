#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_loki.sh
# Purpose : Deploy Loki + Promtail log aggregation stack in zero-touch mode.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"

deploy_loki_stack() {
    log_banner
    log_section "Despliegue del Stack de Logs (Loki + Promtail DaemonSet)"

    local kubeconfig="${HOME}/.kube/config"
    [[ ! -f "${kubeconfig}" ]] && kubeconfig="/etc/kubernetes/admin.conf"
    export KUBECONFIG="${kubeconfig}"

    local manifest="${SUITE_ROOT}/manifests/base/monitoring/promtail-loki.yaml"
    if [[ ! -f "${manifest}" ]]; then
        log_error "Manifiesto de Loki no encontrado: ${manifest}"
        return 1
    fi

    # Ensure default StorageClass exists for PVC auto-binding
    if ! kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
        log_info "No se detectó StorageClass por defecto. Aprovisionando StorageClass local para PV/PVC..."
        local storage_manifest="${SUITE_ROOT}/manifests/base/storage/local-storage-provisioner.yaml"
        if [[ -f "${storage_manifest}" ]]; then
            kubectl apply -f "${storage_manifest}"
            log_success "StorageClass 'local-path' aprovisionada dinámicamente."
        fi
    fi

    log_info "Aplicando manifiestos de Loki + Promtail en el namespace 'monitoring'..."
    if ! kubectl apply -f "${manifest}"; then
        log_warn "Error aplicando el manifiesto (campos inmutables en StatefulSet). Forzando reemplazo..."
        kubectl replace --force -f "${manifest}"
    fi

    log_info "Esperando disponibilidad de Loki y Promtail..."
    kubectl rollout status statefulset/loki -n monitoring --timeout=120s || true
    kubectl rollout status daemonset/promtail -n monitoring --timeout=120s || true

    log_section "🎉 Stack de Logs (Loki + Promtail) Desplegado Exitosamente"
    printf "  %-30s %s\n" "Loki Internal Endpoint:" "http://loki.monitoring.svc.cluster.local:3100"
    printf "  %-30s %s\n" "Promtail Log Collector:" "DaemonSet en todos los nodos"
    printf "  %-30s %s\n\n" "Grafana Data Source:" "Loki (URL: http://loki.monitoring.svc:3100)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_loki_stack "$@"
fi

#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_monitoring.sh
# Purpose : Unified 360° Observability Stack Installer
#           Deploys Prometheus + Grafana + Alertmanager + Loki + Promtail
#           in 1-Click for metrics, alerts, and centralized log management.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/network_check.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/stack/deploy_loki.sh"

readonly MONITORING_NS="monitoring"
readonly PROMETHEUS_RELEASE="prometheus-stack"

_ensure_namespace() {
    local ns="${1}"
    kubectl create namespace "${ns}" --dry-run=client -o yaml | \
        kubectl apply -f - 2>/dev/null || true
    log_success "Namespace preparado: ${ns}"
}

_install_helm() {
    if command -v helm &>/dev/null; then
        log_info "Helm ya está instalado: $(helm version --short 2>/dev/null)"
        return 0
    fi

    log_info "Instalando Helm..."
    if net_is_online; then
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    else
        local helm_bin
        helm_bin=$(find "${SUITE_ROOT}/offline-assets" -name "helm" -type f 2>/dev/null | head -1 || echo "")
        if [[ -n "${helm_bin}" ]]; then
            sudo install -m 755 "${helm_bin}" /usr/local/bin/helm
        else
            log_warn "Binario de Helm no encontrado en offline-assets — usando manifiestos kubectl"
            return 1
        fi
    fi
    log_success "Helm instalado correctamente"
}

_deploy_online() {
    log_info "[1/2] Desplegando kube-prometheus-stack (Prometheus + Grafana + Alertmanager)..."

    helm repo add prometheus-community \
        https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update

    # Configurar DataSource automático de Loki en Grafana
    helm upgrade --install "${PROMETHEUS_RELEASE}" \
        prometheus-community/kube-prometheus-stack \
        --namespace "${MONITORING_NS}" \
        --create-namespace \
        --set prometheus.prometheusSpec.retention=30d \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi \
        --set grafana.adminPassword="admin" \
        --set grafana.service.type=NodePort \
        --set grafana.service.nodePort=32000 \
        --set alertmanager.enabled=true \
        --set "grafana.additionalDataSources[0].name=Loki" \
        --set "grafana.additionalDataSources[0].type=loki" \
        --set "grafana.additionalDataSources[0].url=http://loki.monitoring.svc.cluster.local:3100" \
        --set "grafana.additionalDataSources[0].access=proxy" \
        --wait --timeout=10m

    log_success "kube-prometheus-stack desplegado y vinculado con Loki"
}

_deploy_airgap() {
    log_info "[1/2] Desplegando stack de observabilidad desde manifiestos offline (AIR-GAP mode)..."

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
        log_success "Observabilidad desplegada desde manifiesto offline"
    else
        log_warn "No se encontraron manifiestos offline en offline-assets/"
    fi
}

_print_summary() {
    log_section "📊 STACK UNIFICADO DE OBSERVABILIDAD 360° — ACTIVO"

    local node_ip
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "IP_NODO")

    printf "\n  ${CLR_BOLD_WHITE}Resumen de Componentes Desplegados:${CLR_RESET}\n"
    printf "  %-30s %s\n" "1. Métricas del Clúster:" "Prometheus v2.x (Retención: 30d)"
    printf "  %-30s %s\n" "2. Gestor de Alertas:" "Alertmanager (Habilitado)"
    printf "  %-30s %s\n" "3. Motor de Logs Centralizado:" "Loki StatefulSet + Promtail DaemonSet"
    printf "  %-30s %s\n" "4. Panel Visual Unificado:" "Grafana (DataSources: Prometheus + Loki)"

    printf "\n  ${CLR_BOLD_WHITE}Acceso al Dashboard Grafana Unificado:${CLR_RESET}\n"
    printf "  %-30s ${CLR_BOLD_GREEN}http://%s:32000${CLR_RESET}\n" "URL Grafana (NodePort):" "${node_ip}"
    printf "  %-30s %s\n" "Usuario Predeterminado:" "admin"
    printf "  %-30s %s\n\n" "Contraseña Grafana:" "admin"

    printf "  ${CLR_BOLD_WHITE}Verificación de Estado (Pods en namespace monitoring):${CLR_RESET}\n"
    printf "  ${CLR_YELLOW}kubectl get pods -n %s -o wide${CLR_RESET}\n\n" "${MONITORING_NS}"
}

main() {
    log_banner
    log_section "Desplegando Stack Unificado de Observabilidad (Prometheus + Loki + Grafana)"

    net_detect_mode

    local kubeconfig="${HOME}/.kube/config"
    [[ ! -f "${kubeconfig}" ]] && kubeconfig="/etc/kubernetes/admin.conf"
    export KUBECONFIG="${kubeconfig}"

    _ensure_namespace "${MONITORING_NS}"

    # Paso 1: Desplegar Prometheus + Grafana + Alertmanager
    if _install_helm 2>/dev/null; then
        if net_is_online; then
            _deploy_online
        else
            _deploy_airgap
        fi
    else
        _deploy_airgap
    fi

    # Paso 2: Desplegar Loki + Promtail DaemonSet
    log_info "[2/2] Desplegando Loki + Promtail DaemonSet para recolectar logs de todos los pods..."
    deploy_loki_stack || true

    _print_summary

    log_success "¡Stack Unificado de Observabilidad 360° Desplegado Exitosamente!"
    pause "Presione [Enter] para retornar al menú principal..."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

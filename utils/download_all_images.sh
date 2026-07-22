#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: utils/download_all_images.sh
# Purpose : Download and export all 29 enterprise Kubernetes images into a single
#           compressed offline tarball bundle (kubeops-airgap-images.tar.gz)
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SUITE_ROOT}/lib/logger.sh" 2>/dev/null || {
    log_info() { printf "\033[1;36m[INFO]\033[0m  %s\n" "$*"; }
    log_success() { printf "\033[1;32m[  OK  ]\033[0m %s\n" "$*"; }
    log_warn() { printf "\033[1;33m[ WARN ]\033[0m %s\n" "$*"; }
    log_error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; }
}

DEST_DIR="${SUITE_ROOT}/offline-images"
BUNDLE_FILE="${SUITE_ROOT}/kubeops-airgap-images.tar.gz"

REQUIRED_IMAGES=(
    # Kubernetes Core
    "registry.k8s.io/kube-apiserver:v1.29.15"
    "registry.k8s.io/kube-controller-manager:v1.29.15"
    "registry.k8s.io/kube-scheduler:v1.29.15"
    "registry.k8s.io/kube-proxy:v1.29.15"
    "registry.k8s.io/etcd:3.5.12-0"
    "registry.k8s.io/coredns/coredns:v1.11.1"
    "registry.k8s.io/pause:3.9"

    # CNI Network & Observability (Cilium)
    "quay.io/cilium/cilium:v1.15.5"
    "quay.io/cilium/operator-generic:v1.15.5"
    "quay.io/cilium/hubble-relay:v1.15.5"
    "quay.io/cilium/hubble-ui:v0.12.1"
    "quay.io/cilium/hubble-ui-backend:v0.12.1"

    # Observabilidad (Prometheus, Grafana, Loki)
    "prom/prometheus:v2.51.0"
    "grafana/grafana:10.4.0"
    "prom/alertmanager:v0.27.0"
    "grafana/loki:2.9.4"
    "grafana/promtail:2.9.4"
    "quay.io/prometheus-operator/prometheus-config-reloader:v0.72.0"

    # Service Mesh & Ingress (Istio, Kiali, Kong)
    "docker.io/istio/pilot:1.21.0"
    "docker.io/istio/proxyv2:1.21.0"
    "quay.io/kiali/kiali:v1.80.0"
    "kong:3.6"
    "redis:7.2"

    # GitOps & Backups (ArgoCD, Velero, Cert-Manager, OpenEBS)
    "quay.io/argoproj/argocd:v2.10.4"
    "velero/velero:v1.13.0"
    "quay.io/jetstack/cert-manager-controller:v1.14.4"
    "quay.io/jetstack/cert-manager-cainjector:v1.14.4"
    "quay.io/jetstack/cert-manager-webhook:v1.14.4"
    "openebs/provisioner-localpv:3.5.0"
)

log_section "📦 Descarga y Empaquetado de Imágenes Air-Gap"
log_info "Directorio de almacenamiento temporal: ${DEST_DIR}"
mkdir -p "${DEST_DIR}"

total=${#REQUIRED_IMAGES[@]}
current=0

for img in "${REQUIRED_IMAGES[@]}"; do
    current=$((current + 1))
    log_info "[${current}/${total}] Descargando imagen: ${img}"
    sudo docker pull "${img}" || log_warn "Falló pull de ${img}"
done

log_info "Exportando imágenes en paquete tar comprimido..."
sudo docker save "${REQUIRED_IMAGES[@]}" | gzip -c > "${BUNDLE_FILE}"

log_success "🎉 ¡PAQUETE DE IMÁGENES AIR-GAP CREADO CON ÉXITO!"
log_info "Ubicación del paquete: ${BUNDLE_FILE}"
log_info "Para cargar las imágenes en un servidor sin internet execute: docker load < ${BUNDLE_FILE}"

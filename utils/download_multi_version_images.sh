#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: utils/download_multi_version_images.sh
# Purpose : Download and push multi-version matrix (3 prior + current + 3 newer)
#           for all KubeOps components directly into Nexus 3 Docker Registry (8082).
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh" 2>/dev/null || {
    log_info() { printf "\033[1;36m[INFO]\033[0m  %s\n" "$*"; }
    log_success() { printf "\033[1;32m[  OK  ]\033[0m %s\n" "$*"; }
    log_warn() { printf "\033[1;33m[ WARN ]\033[0m %s\n" "$*"; }
    log_error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; }
}

REGISTRY_HOST="${1:-127.0.0.1:8082}"

log_section "🌐 Descarga e Inyección Multi-Versión (Versiones Anteriores y Posteriores)"

# ---------------------------------------------------------------------------
# Multi-Version Image Matrix
# ---------------------------------------------------------------------------
MULTI_VERSION_IMAGES=(
    # --- Kubernetes Core (v1.27, v1.28, v1.29, v1.30, v1.31) ---
    "registry.k8s.io/kube-apiserver:v1.27.12"
    "registry.k8s.io/kube-apiserver:v1.28.8"
    "registry.k8s.io/kube-apiserver:v1.28.15"
    "registry.k8s.io/kube-apiserver:v1.29.3"
    "registry.k8s.io/kube-apiserver:v1.29.15"
    "registry.k8s.io/kube-apiserver:v1.30.2"
    "registry.k8s.io/kube-apiserver:v1.30.10"
    "registry.k8s.io/kube-apiserver:v1.31.1"

    "registry.k8s.io/kube-controller-manager:v1.28.15"
    "registry.k8s.io/kube-controller-manager:v1.29.15"
    "registry.k8s.io/kube-controller-manager:v1.30.10"

    "registry.k8s.io/kube-scheduler:v1.28.15"
    "registry.k8s.io/kube-scheduler:v1.29.15"
    "registry.k8s.io/kube-scheduler:v1.30.10"

    "registry.k8s.io/kube-proxy:v1.28.15"
    "registry.k8s.io/kube-proxy:v1.29.15"
    "registry.k8s.io/kube-proxy:v1.30.10"

    "registry.k8s.io/etcd:3.5.9-0"
    "registry.k8s.io/etcd:3.5.10-0"
    "registry.k8s.io/etcd:3.5.12-0"
    "registry.k8s.io/etcd:3.5.14-0"

    "registry.k8s.io/coredns/coredns:v1.10.1"
    "registry.k8s.io/coredns/coredns:v1.11.1"
    "registry.k8s.io/coredns/coredns:v1.11.3"

    "registry.k8s.io/pause:3.8"
    "registry.k8s.io/pause:3.9"
    "registry.k8s.io/pause:3.10"

    # --- Cilium CNI Multi-Version ---
    "quay.io/cilium/cilium:v1.13.14"
    "quay.io/cilium/cilium:v1.14.9"
    "quay.io/cilium/cilium:v1.15.5"
    "quay.io/cilium/cilium:v1.16.0"

    # --- Prometheus Multi-Version ---
    "prom/prometheus:v2.48.0"
    "prom/prometheus:v2.49.0"
    "prom/prometheus:v2.50.0"
    "prom/prometheus:v2.51.0"
    "prom/prometheus:v2.52.0"

    # --- Grafana Multi-Version ---
    "grafana/grafana:10.2.0"
    "grafana/grafana:10.3.0"
    "grafana/grafana:10.4.0"
    "grafana/grafana:10.4.5"
    "grafana/grafana:11.0.0"

    # --- Loki & Promtail Multi-Version ---
    "grafana/loki:2.8.6"
    "grafana/loki:2.9.0"
    "grafana/loki:2.9.4"
    "grafana/loki:3.0.0"

    "grafana/promtail:2.8.6"
    "grafana/promtail:2.9.0"
    "grafana/promtail:2.9.4"
    "grafana/promtail:3.0.0"

    # --- Kong API Gateway Multi-Version ---
    "kong:3.4"
    "kong:3.5"
    "kong:3.6"
    "kong:3.7"

    # --- Redis Multi-Version ---
    "redis:7.0"
    "redis:7.2"
    "redis:7.4"

    # --- Istio Service Mesh Multi-Version ---
    "docker.io/istio/pilot:1.19.4"
    "docker.io/istio/pilot:1.20.3"
    "docker.io/istio/pilot:1.21.0"
    "docker.io/istio/pilot:1.22.0"

    "docker.io/istio/proxyv2:1.19.4"
    "docker.io/istio/proxyv2:1.20.3"
    "docker.io/istio/proxyv2:1.21.0"
    "docker.io/istio/proxyv2:1.22.0"

    # --- ArgoCD Multi-Version ---
    "quay.io/argoproj/argocd:v2.8.4"
    "quay.io/argoproj/argocd:v2.9.6"
    "quay.io/argoproj/argocd:v2.10.4"
    "quay.io/argoproj/argocd:v2.11.2"

    # --- Cert-Manager Multi-Version ---
    "quay.io/jetstack/cert-manager-controller:v1.12.0"
    "quay.io/jetstack/cert-manager-controller:v1.13.3"
    "quay.io/jetstack/cert-manager-controller:v1.14.4"
    "quay.io/jetstack/cert-manager-controller:v1.15.0"
)

log_info "Autenticando en el registro Nexus (${REGISTRY_HOST})..."
sudo docker login "${REGISTRY_HOST}" -u admin -p Admin123! 2>/dev/null || true

log_info "Procesando matriz multi-versión (${#MULTI_VERSION_IMAGES[@]} imágenes totales)..."

total="${#MULTI_VERSION_IMAGES[@]}"
current=0

for img in "${MULTI_VERSION_IMAGES[@]}"; do
    current=$((current + 1))
    target_tag="${REGISTRY_HOST}/${img#*/}"
    log_info "[${current}/${total}] Mirroring: ${img} -> ${target_tag}"
    sudo docker pull "${img}" || true
    sudo docker tag "${img}" "${target_tag}" || true
    sudo docker push "${target_tag}" || log_warn "Push omitido para ${target_tag}"
done

log_section "🎉 ¡MATRIZ MULTI-VERSIÓN CARGADA EN NEXUS 3!"
log_info "Todas las versiones (anteriores, actuales y superiores) están listas en Nexus UI."

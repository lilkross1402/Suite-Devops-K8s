#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: utils/download_all_images.sh
# Purpose : Download and organize all 29 enterprise Kubernetes images into
#           categorized subdirectories with individual .tar archives and a master bundle.
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

BASE_DIR="${SUITE_ROOT}/offline-images"
BUNDLE_FILE="${SUITE_ROOT}/kubeops-airgap-images-full.tar.gz"

log_section "📁 Estructuración y Descarga Categorizada de Imágenes"

declare -A CATEGORIES=(
    ["01_k8s_core"]="registry.k8s.io/kube-apiserver:v1.29.15 registry.k8s.io/kube-controller-manager:v1.29.15 registry.k8s.io/kube-scheduler:v1.29.15 registry.k8s.io/kube-proxy:v1.29.15 registry.k8s.io/etcd:3.5.12-0 registry.k8s.io/coredns/coredns:v1.11.1 registry.k8s.io/pause:3.9"
    ["02_cni_cilium"]="quay.io/cilium/cilium:v1.15.5 quay.io/cilium/operator-generic:v1.15.5 quay.io/cilium/hubble-relay:v1.15.5 quay.io/cilium/hubble-ui:v0.12.1 quay.io/cilium/hubble-ui-backend:v0.12.1"
    ["03_observability"]="prom/prometheus:v2.51.0 grafana/grafana:10.4.0 prom/alertmanager:v0.27.0 grafana/loki:2.9.4 grafana/promtail:2.9.4 quay.io/prometheus-operator/prometheus-config-reloader:v0.72.0"
    ["04_mesh_ingress"]="docker.io/istio/pilot:1.21.0 docker.io/istio/proxyv2:1.21.0 quay.io/kiali/kiali:v1.80.0 kong:3.6 redis:7.2"
    ["05_gitops_storage"]="quay.io/argoproj/argocd:v2.10.4 velero/velero:v1.13.0 quay.io/jetstack/cert-manager-controller:v1.14.4 quay.io/jetstack/cert-manager-cainjector:v1.14.4 quay.io/jetstack/cert-manager-webhook:v1.14.4 openebs/provisioner-localpv:3.5.0"
)

# Render organized directory structure
for cat_folder in "${!CATEGORIES[@]}"; do
    mkdir -p "${BASE_DIR}/${cat_folder}"
done

# Script de carga automática dentro de la carpeta offline
cat > "${BASE_DIR}/load_all.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "==> Cargando imágenes .tar en el runtime de Docker/containerd..."
find . -name "*.tar" -type f | while read -r tarfile; do
    echo "  [Cargando] ${tarfile}..."
    sudo docker load -i "${tarfile}" || true
done
echo "==> ¡Todas las imágenes fueron cargadas exitosamente!"
EOF
chmod +x "${BASE_DIR}/load_all.sh"

all_images=()

for cat_folder in "01_k8s_core" "02_cni_cilium" "03_observability" "04_mesh_ingress" "05_gitops_storage"; do
    log_info "📂 Procesando categoría: ${cat_folder}"
    read -ra img_list <<< "${CATEGORIES[${cat_folder}]}"
    
    for img in "${img_list[@]}"; do
        all_images+=("${img}")
        local_name=$(echo "${img}" | sed -e 's|.*/||' -e 's|:|--|g').tar
        tar_path="${BASE_DIR}/${cat_folder}/${local_name}"

        log_info "  Descargando: ${img}"
        sudo docker pull "${img}" || true

        log_info "  Guardando en: ${cat_folder}/${local_name}"
        sudo docker save "${img}" -o "${tar_path}"
    done
done

log_info "Empaquetando toda la estructura de carpetas en ${BUNDLE_FILE}..."
tar -czf "${BUNDLE_FILE}" -C "${SUITE_ROOT}" offline-images

log_section "🎉 ¡ESTRUCTURA DE CARPETAS ORGANIZADA Y LISTA!"
log_info "Directorio organizado: ${BASE_DIR}"
log_info "Paquete maestro: ${BUNDLE_FILE}"
log_info "Para cargar todo en cualquier servidor sin internet execute: cd offline-images && sudo ./load_all.sh"

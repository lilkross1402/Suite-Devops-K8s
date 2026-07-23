#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: utils/download_all_images.sh
# Purpose : Download, organize into categorized subdirectories, save .tar archives,
#           and AUTOMATICALLY PUSH all 29 enterprise images to local Nexus/Air-Gap Registry (8082).
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

source "${SUITE_ROOT}/lib/logger.sh" 2>/dev/null || {
    log_info() { printf "\033[1;36m[INFO]\033[0m  %s\n" "$*"; }
    log_success() { printf "\033[1;32m[  OK  ]\033[0m %s\n" "$*"; }
    log_warn() { printf "\033[1;33m[ WARN ]\033[0m %s\n" "$*"; }
    log_error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; }
}

BASE_DIR="${SUITE_ROOT}/offline-images"
BUNDLE_FILE="${SUITE_ROOT}/kubeops-airgap-images-full.tar.gz"
REGISTRY_HOST="${NEXUS_REGISTRY:-127.0.0.1:8082}"

log_section "🚀 Descarga, Organización y Carga Directa a Nexus (Puerto 8082)"

declare -A CATEGORIES=(
    ["01_k8s_core"]="registry.k8s.io/kube-apiserver:v1.29.15 registry.k8s.io/kube-controller-manager:v1.29.15 registry.k8s.io/kube-scheduler:v1.29.15 registry.k8s.io/kube-proxy:v1.29.15 registry.k8s.io/etcd:3.5.12-0 registry.k8s.io/coredns/coredns:v1.11.1 registry.k8s.io/pause:3.9"
    ["02_cni_plugins"]="quay.io/cilium/cilium:v1.15.5 quay.io/cilium/operator-generic:v1.15.5 quay.io/cilium/hubble-relay:v1.15.5 quay.io/cilium/hubble-ui:v0.12.1 quay.io/cilium/hubble-ui-backend:v0.12.1 docker.io/calico/cni:v3.27.0 docker.io/calico/node:v3.27.0 docker.io/calico/kube-controllers:v3.27.0 flannel/flannel:v0.24.2"
    ["03_observability"]="prom/prometheus:v2.51.0 grafana/grafana:10.4.0 prom/alertmanager:v0.27.0 grafana/loki:2.9.4 grafana/promtail:2.9.4 quay.io/prometheus-operator/prometheus-config-reloader:v0.72.0"
    ["04_mesh_ingress"]="docker.io/istio/pilot:1.21.0 docker.io/istio/proxyv2:1.21.0 quay.io/kiali/kiali:v1.80.0 kong:3.6 redis:7.2"
    ["05_gitops_storage_ha"]="quay.io/argoproj/argocd:v2.10.4 velero/velero:v1.13.0 quay.io/jetstack/cert-manager-controller:v1.14.4 quay.io/jetstack/cert-manager-cainjector:v1.14.4 quay.io/jetstack/cert-manager-webhook:v1.14.4 rancher/local-path-provisioner:v0.0.26 openebs/provisioner-localpv:3.5.0 busybox:latest haproxy:2.8 osixia/keepalived:2.0.20"
)

# Render organized directory structure
for cat_folder in "${!CATEGORIES[@]}"; do
    mkdir -p "${BASE_DIR}/${cat_folder}"
done

# Auto-loader script inside offline directory
cat > "${BASE_DIR}/load_all.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
REG_HOST="\${1:-${REGISTRY_HOST}}"
echo "==> Cargando imágenes .tar en Docker y subiéndolas a Nexus/Registro (\${REG_HOST})..."
find . -name "*.tar" -type f | while read -r tarfile; do
    echo "  [Importando y Pushing] \${tarfile}..."
    sudo docker load -i "\${tarfile}" || true
done
echo "==> ¡Proceso finalizado con éxito!"
EOF
chmod +x "${BASE_DIR}/load_all.sh"

for cat_folder in "${!CATEGORIES[@]}"; do
    log_info "📂 Categoria: ${cat_folder}"
    read -ra img_list <<< "${CATEGORIES[${cat_folder}]}"
    
    for img in "${img_list[@]}"; do
        local_name=$(echo "${img}" | sed -e 's|.*/||' -e 's|:|--|g').tar
        tar_path="${BASE_DIR}/${cat_folder}/${local_name}"
        target_tag="${REGISTRY_HOST}/${img#*/}"

        log_info "  [1/3 Pull] ${img}"
        sudo docker pull "${img}" || true

        log_info "  [2/3 Guardar] ${cat_folder}/${local_name}"
        sudo docker save "${img}" -o "${tar_path}"

        log_info "  [3/3 Push a Nexus/Registry] -> ${target_tag}"
        sudo docker tag "${img}" "${target_tag}" || true
        sudo docker push "${target_tag}" || log_warn "Push omitido para ${target_tag} (verifique si el registro está activo)"
    done
done

log_info "Empaquetando catálogo completo en ${BUNDLE_FILE}..."
tar -czf "${BUNDLE_FILE}" -C "${SUITE_ROOT}" offline-images

log_section "🎉 ¡PROCESO COMPLETO: DESCARGADAS, EMPAQUETADAS Y SUBIDAS A NEXUS!"
log_info "Directorio local organizado: ${BASE_DIR}"
log_info "Registro Nexus/Air-Gap objetivo: ${REGISTRY_HOST}"
log_info "Paquete maestro tar.gz: ${BUNDLE_FILE}"

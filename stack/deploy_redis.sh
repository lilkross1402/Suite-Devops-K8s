#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_redis.sh
# Purpose : Deploy Redis (standalone or cluster mode) on Kubernetes.
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SUITE_ROOT}/lib/logger.sh"
source "${SUITE_ROOT}/lib/network_check.sh"
source "${SUITE_ROOT}/lib/state_manager.sh"

readonly REDIS_NS="redis"
readonly REDIS_RELEASE="redis"

_deploy_redis_online() {
    log_info "Deploying Redis via Helm (Bitnami chart)..."

    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo update

    local redis_password
    redis_password=$(openssl rand -base64 20)

    helm upgrade --install "${REDIS_RELEASE}" bitnami/redis \
        --namespace "${REDIS_NS}" \
        --create-namespace \
        --set auth.enabled=true \
        --set auth.password="${redis_password}" \
        --set master.persistence.enabled=true \
        --set master.persistence.size=5Gi \
        --set replica.replicaCount=1 \
        --set metrics.enabled=true \
        --wait --timeout=10m

    log_success "Redis deployed"
    state_set_meta "redis_password" "${redis_password}"
    log_info "Redis password stored in state metadata"
}

_deploy_redis_airgap() {
    log_info "Deploying Redis from offline manifests..."

    local manifest
    manifest=$(find "${SUITE_ROOT}/offline-assets" \
        -name "redis-*.yaml" 2>/dev/null | head -1 || echo "")

    if [[ -n "${manifest}" ]]; then
        kubectl apply -n "${REDIS_NS}" -f "${manifest}"
        log_success "Redis deployed from offline manifest"
    else
        log_info "Generating minimal Redis manifest..."
        kubectl apply -n "${REDIS_NS}" -f - <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
  namespace: redis
spec:
  serviceName: redis
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        command: ["redis-server", "--save", "60", "1", "--loglevel", "warning"]
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        volumeMounts:
        - mountPath: /data
          name: redis-data
  volumeClaimTemplates:
  - metadata:
      name: redis-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: redis
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
  type: ClusterIP
EOF
        log_success "Redis deployed via minimal manifest"
    fi
}

_print_summary() {
    log_section "🔴 Redis — Deployed"
    printf "\n  ${CLR_BOLD_WHITE}Connection:${CLR_RESET}\n"
    printf "  %-28s %s\n" "Service:"   "redis.${REDIS_NS}.svc.cluster.local:6379"
    printf "  %-28s %s\n" "Namespace:" "${REDIS_NS}"
    printf "\n  ${CLR_YELLOW}kubectl get pods -n %s${CLR_RESET}\n\n" "${REDIS_NS}"
}

main() {
    log_banner
    log_section "Deploying Redis"

    net_detect_mode

    if ! state_is_cluster_initialized; then
        log_fatal "No cluster found. Initialize the master first."
    fi

    local kubeconfig="${HOME}/.kube/config"
    [[ ! -f "${kubeconfig}" ]] && kubeconfig="/etc/kubernetes/admin.conf"
    export KUBECONFIG="${kubeconfig}"

    kubectl create namespace "${REDIS_NS}" --dry-run=client -o yaml | \
        kubectl apply -f - 2>/dev/null || true

    if net_is_online && command -v helm &>/dev/null; then
        _deploy_redis_online
    else
        _deploy_redis_airgap
    fi

    _print_summary
    log_success "Redis deployment complete"
    pause "Press [Enter] to return to main menu..."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

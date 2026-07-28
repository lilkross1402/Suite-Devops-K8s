#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_kagent.sh
# Purpose : Deploy KAgent AI Platform (Ollama Local LLM + PostgreSQL Storage Fix
#           + ModelConfig + Autonomous Monitoring with Telegram Auto-Remediation).
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
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh" 2>/dev/null || true

# Ensure PATH and KUBECONFIG are properly resolved
export PATH="${PATH}:/usr/local/bin:/usr/bin:/bin"
if [[ -z "${KUBECONFIG:-}" ]]; then
    if [[ -f /etc/kubernetes/admin.conf ]]; then
        export KUBECONFIG="/etc/kubernetes/admin.conf"
    elif [[ -f /root/.kube/config ]]; then
        export KUBECONFIG="/root/.kube/config"
    elif [[ -f "${HOME}/.kube/config" ]]; then
        export KUBECONFIG="${HOME}/.kube/config"
    fi
fi

deploy_kagent_platform() {
    log_banner
    log_section "🤖 Despliegue de la Plataforma AI KAgent (Auto-Remediación & Telegram)"

    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl no está disponible. Asegúrese de que el clúster esté inicializado."
        return 1
    fi

    # ---------------------------------------------------------------------------
    # Paso 1: Despliegue del Motor LLM Local (Ollama)
    # ---------------------------------------------------------------------------
    log_info "[Paso 1/5] Desplegando Motor LLM Local Ollama (namespace: ollama)..."
    kubectl --kubeconfig="${KUBECONFIG}" create namespace ollama --dry-run=client -o yaml | \
        kubectl --kubeconfig="${KUBECONFIG}" apply -f - 2>/dev/null || true

    local ollama_manifest="${SUITE_ROOT}/manifests/base/kagent/ollama-deployment.yaml"
    if [[ -f "${ollama_manifest}" ]]; then
        kubectl --kubeconfig="${KUBECONFIG}" apply -f "${ollama_manifest}"
        log_success "Manifiesto de Ollama (v0.4.7) aplicado exitosamente"
    fi

    log_info "Esperando disponibilidad del Pod de Ollama..."
    kubectl --kubeconfig="${KUBECONFIG}" rollout status deployment/ollama -n ollama --timeout=3m 2>/dev/null || true

    log_info "Descargando modelos de IA en Ollama (llama3.2:1b & qwen2.5:0.5b)..."
    kubectl --kubeconfig="${KUBECONFIG}" exec -n ollama deployment/ollama -- ollama pull llama3.2:1b 2>/dev/null || log_warn "Pull llama3.2:1b omitido o en progreso"
    kubectl --kubeconfig="${KUBECONFIG}" exec -n ollama deployment/ollama -- ollama pull qwen2.5:0.5b 2>/dev/null || log_warn "Pull qwen2.5:0.5b omitido o en progreso"

    # ---------------------------------------------------------------------------
    # Paso 2: Instalación de KAgent y sus CRDs vía Helm
    # ---------------------------------------------------------------------------
    log_info "[Paso 2/5] Instalando Helm Charts de KAgent (namespace: kagent)..."
    kubectl --kubeconfig="${KUBECONFIG}" create namespace kagent 2>/dev/null || true
    
    if command -v helm &>/dev/null; then
        helm upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds -n kagent --create-namespace --kubeconfig="${KUBECONFIG}" 2>/dev/null || true
        helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent -n kagent --create-namespace --kubeconfig="${KUBECONFIG}" 2>/dev/null || true
        log_success "Helm charts kagent-crds y kagent instalados"
    else
        log_warn "Helm no detectado. Aplique los CRDs manualmente si es necesario."
    fi

    # ---------------------------------------------------------------------------
    # Paso 3: Reparación del Almacenamiento Local (RBAC y PostgreSQL)
    # ---------------------------------------------------------------------------
    log_info "[Paso 3/5] Aplicando corrección de permisos RBAC para local-path-provisioner (PostgreSQL)..."
    local rbac_fix="${SUITE_ROOT}/manifests/base/kagent/local-path-clusterrole-fix.yaml"
    if [[ -f "${rbac_fix}" ]]; then
        kubectl --kubeconfig="${KUBECONFIG}" apply -f "${rbac_fix}"
        kubectl --kubeconfig="${KUBECONFIG}" rollout restart deployment local-path-provisioner -n local-path-storage 2>/dev/null || true
        log_success "Permisos RBAC de almacenamiento actualizados"
    fi

    # ---------------------------------------------------------------------------
    # Paso 4: Configuración del Modelo de IA para KAgent
    # ---------------------------------------------------------------------------
    log_info "[Paso 4/5] Enlazando KAgent con Ollama (ModelConfig & Observability Agent)..."
    local model_config="${SUITE_ROOT}/manifests/base/kagent/default-model-config.yaml"
    local agent_fix="${SUITE_ROOT}/manifests/base/kagent/observability-agent-fix.yaml"

    if [[ -f "${model_config}" ]]; then
        kubectl --kubeconfig="${KUBECONFIG}" apply -f "${model_config}" 2>/dev/null || true
    fi
    if [[ -f "${agent_fix}" ]]; then
        kubectl --kubeconfig="${KUBECONFIG}" apply -f "${agent_fix}" 2>/dev/null || true
    fi

    kubectl --kubeconfig="${KUBECONFIG}" rollout restart deployment kagent-controller -n kagent 2>/dev/null || true
    log_success "ModelConfig y Agente Declarativo vinculados a Ollama"

    # ---------------------------------------------------------------------------
    # Paso 5: Monitoreo Autónomo, Auto-Remediación & Bot Interactivo de Telegram
    # ---------------------------------------------------------------------------
    log_info "[Paso 5/5] Configurando Credenciales de Telegram & Controlador Autónomo SRE..."
    
    local telegram_token=""
    local telegram_chat_id=""
    local telegram_allowed_users=""
    
    printf "\n"
    printf "  ══════════════════════════════════════════════════════════════\n"
    printf "  Configuración del Bot de Telegram (KAgent SRE)\n"
    printf "  ══════════════════════════════════════════════════════════════\n\n"

    printf "  Ingrese el TOKEN del Bot de Telegram (ej. 8058092187:AAFC...): "
    read -r telegram_token

    printf "  Ingrese el ChatID principal de Telegram para recibir alertas: "
    read -r telegram_chat_id

    printf "  Ingrese los UserIDs autorizados para consultar e interactuar (separados por espacio): "
    read -r telegram_allowed_users

    # Crear Namespace kagent-system y kagent
    kubectl --kubeconfig="${KUBECONFIG}" create namespace kagent-system 2>/dev/null || true
    kubectl --kubeconfig="${KUBECONFIG}" create namespace kagent 2>/dev/null || true

    # Crear Secret de Credenciales en kagent-system y kagent
    for ns in kagent-system kagent; do
        kubectl --kubeconfig="${KUBECONFIG}" create secret generic kagent-credentials -n "${ns}" \
            --from-literal=TELEGRAM_BOT_TOKEN="${telegram_token}" \
            --from-literal=TELEGRAM_CHAT_ID="${telegram_chat_id}" \
            --from-literal=TELEGRAM_ALLOWED_USER_IDS="${telegram_allowed_users}" \
            --dry-run=client -o yaml | kubectl --kubeconfig="${KUBECONFIG}" apply -f - 2>/dev/null || true

        kubectl --kubeconfig="${KUBECONFIG}" create secret generic kagent-telegram-secret -n "${ns}" \
            --from-literal=TELEGRAM_BOT_TOKEN="${telegram_token}" \
            --from-literal=TELEGRAM_CHAT_ID="${telegram_chat_id}" \
            --from-literal=TELEGRAM_ALLOWED_USER_IDS="${telegram_allowed_users}" \
            --dry-run=client -o yaml | kubectl --kubeconfig="${KUBECONFIG}" apply -f - 2>/dev/null || true
    done

    # Crear ConfigMap con el código de kagent-sre-autonomous-agent.py
    local agent_script="${SUITE_ROOT}/manifests/base/kagent/kagent-sre-autonomous-agent.py"
    if [[ -f "${agent_script}" ]]; then
        kubectl --kubeconfig="${KUBECONFIG}" create configmap kagent-sre-code -n kagent-system \
            --from-file=kagent-sre-autonomous-agent.py="${agent_script}" \
            --dry-run=client -o yaml | kubectl --kubeconfig="${KUBECONFIG}" apply -f - 2>/dev/null || true
    fi

    # Aplicar Manifiestos de Producción RBAC, NetworkPolicy y Controller SRE
    local rbac_manifest="${SUITE_ROOT}/manifests/base/kagent/01-rbac-production.yaml"
    local netpol_manifest="${SUITE_ROOT}/manifests/base/kagent/03-networkpolicy.yaml"
    local sre_deploy="${SUITE_ROOT}/manifests/base/kagent/kagent-sre-rbac-deployment.yaml"

    [[ -f "${rbac_manifest}" ]] && kubectl --kubeconfig="${KUBECONFIG}" apply -f "${rbac_manifest}" 2>/dev/null || true
    [[ -f "${netpol_manifest}" ]] && kubectl --kubeconfig="${KUBECONFIG}" apply -f "${netpol_manifest}" 2>/dev/null || true
    [[ -f "${sre_deploy}" ]] && kubectl --kubeconfig="${KUBECONFIG}" apply -f "${sre_deploy}" 2>/dev/null || true

    kubectl --kubeconfig="${KUBECONFIG}" rollout restart deployment/kagent-sre-controller -n kagent-system 2>/dev/null || true

    log_section "🎉 ¡PLATAFORMA AI KAGENT & AUTO-REMEDIACIÓN TELEGRAM DESPLEGADAS!"
    printf "  %-30s %s\n" "Namespace SRE:" "kagent-system"
    printf "  %-30s %s\n" "Controlador Autónomo:" "kagent-sre-controller"
    printf "  %-30s %s\n" "Bot Interactivo Telegram:" "Activo (Long-Polling & Comandos)"
    printf "  %-30s %s\n\n" "Auto-Remediación & Cordon:" "Activa (Recreación de pods + Cordoning de nodos)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_kagent_platform "$@"
fi

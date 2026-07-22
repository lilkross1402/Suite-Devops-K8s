#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: stack/deploy_gitops_resilience.sh
# Purpose : Declarative provisioner for GitOps Engine (ArgoCD HA), Disaster
#           Recovery (Velero + Schedules) and Adaptable Storage (OpenEBS / NFS).
# Author  : KubeOps-Suite (Principal Platform Engineer)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SUITE_ROOT:-}" ]]; then
    SUITE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Guard against multiple sourcing
if [[ -n "${_GITOPS_RESILIENCE_SH_LOADED:-}" ]]; then
    return 0
fi
_GITOPS_RESILIENCE_SH_LOADED=true

# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/logger.sh"
# shellcheck disable=SC1090
source "${SUITE_ROOT}/lib/state_manager.sh"

deploy_storage_class() {
    log_banner
    log_section "Aprovisionamiento de Almacenamiento (OpenEBS / NFS Provisioner)"

    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl no está instalado o disponible en PATH."
        return 1
    fi

    printf "  Seleccione la estrategia de almacenamiento:\n"
    printf "  [1] OpenEBS LocalPV (Almacenamiento local en disco de workers - Recomendado)\n"
    printf "  [2] NFS Subdir External Provisioner (Servidor NFS / NAS Corporativo)\n"
    printf "  Opcion › "
    read -r stg_choice

    if [[ "${stg_choice}" == "2" ]]; then
        local nfs_server nfs_path
        printf "  Ingrese la IP del Servidor NFS Corporativo: "
        read -r nfs_server
        printf "  Ingrese la Ruta Exportada del Servidor NFS (ej. /srv/nfs/k8s): "
        read -r nfs_path

        log_info "Desplegando NFS Subdir External Provisioner (Server: ${nfs_server}, Path: ${nfs_path})..."
        kubectl apply -f "${SUITE_ROOT}/manifests/base/nfs-provisioner/nfs-provisioner.yaml"

        # Patch deployment with user parameters
        kubectl patch deployment nfs-client-provisioner -n nfs-provisioner --type='json' -p="[
            {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/env/0/value\", \"value\": \"${nfs_server}\"},
            {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/env/1/value\", \"value\": \"${nfs_path}\"},
            {\"op\": \"replace\", \"path\": \"/spec/template/spec/volumes/0/nfs/server\", \"value\": \"${nfs_server}\"},
            {\"op\": \"replace\", \"path\": \"/spec/template/spec/volumes/0/nfs/path\", \"value\": \"${nfs_path}\"}
        ]" 2>/dev/null || true
        log_success "NFS Provisioner desplegado y configurado."
    else
        log_info "Desplegando OpenEBS LocalPV (StorageClass predeterminada)..."
        kubectl apply -f "https://openebs.github.io/charts/openebs-operator.yaml" 2>/dev/null || \
        kubectl apply -f "${SUITE_ROOT}/manifests/base/openebs/openebs-storageclass.yaml"
        log_success "OpenEBS LocalPV StorageClass configurado exitosamente."
    fi

    state_set ".stack.storage.installed" "true"
}

deploy_argocd() {
    log_banner
    log_section "Despliegue de ArgoCD HA (Motor GitOps)"

    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl no está instalado o disponible en PATH."
        return 1
    fi

    log_info "Creando namespace argocd..."
    kubectl create namespace argocd 2>/dev/null || true

    local argocd_ver="v2.10.4"
    log_info "Aplicando manifiestos declarativos de ArgoCD HA ${argocd_ver}..."
    kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${argocd_ver}/manifests/ha/install.yaml"

    log_info "Exponiendo ArgoCD Server vía NodePort en puerto 30080..."
    kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort", "ports": [{"name": "http", "port": 80, "nodePort": 30080}, {"name": "https", "port": 443, "nodePort": 30443}]}}' 2>/dev/null || true

    state_set ".stack.argocd.installed" "true"
    state_set ".stack.argocd.version" "${argocd_ver}"

    log_success "¡ArgoCD HA desplegado exitosamente!"
    printf "  ${CLR_BOLD_WHITE}Acceso Web a ArgoCD Dashboard:${CLR_RESET}\n"
    printf "  ${CLR_BOLD_CYAN}http://<IP_MASTER_O_PUBLIC_IP>:30080${CLR_RESET}\n"
    printf "  ${CLR_BOLD_WHITE}Comando para obtener contraseña inicial de admin:${CLR_RESET}\n"
    printf "  ${CLR_BOLD_YELLOW}kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d; echo${CLR_RESET}\n\n"
}

deploy_velero() {
    log_banner
    log_section "Despliegue de Velero (Resiliencia y Backups)"

    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl no está instalado o disponible en PATH."
        return 1
    fi

    log_info "Creando namespace velero..."
    kubectl create namespace velero 2>/dev/null || true

    log_info "Aplicando manifiestos de programación de copias de seguridad semanales/diarias..."
    kubectl apply -f "${SUITE_ROOT}/manifests/base/velero/velero-schedule.yaml" 2>/dev/null || true

    state_set ".stack.velero.installed" "true"
    log_success "¡Componente Velero y programaciones de backup registrados exitosamente!"
}

show_gitops_resilience_menu() {
    while true; do
        log_banner
        log_section "🛡️  MÓDULO DE GITOPS, RESILIENCIA Y ALMACENAMIENTO ENTERPRISE"

        printf "  %-5s %-4s %-32s %s\n" "[1]" "💾" "Aprovisionador de Almacenamiento" "OpenEBS LocalPV o NFS Corporativo"
        printf "  %-5s %-4s %-32s %s\n" "[2]" "🐙" "ArgoCD HA (Motor GitOps)" "Desplegar ArgoCD HA (Puerto 30080)"
        printf "  %-5s %-4s %-32s %s\n" "[3]" "🛡️ " "Velero (Disaster Recovery & Backup)" "Respaldo diario de etcd y volúmenes"
        printf "  %-5s %-4s %-32s %s\n" "[A]" "⚡" "INSTALAR GITOPS & RESILIENCIA COMPLETO" "Instalar Storage + ArgoCD + Velero"
        printf "  %-5s %-4s %-32s %s\n" "[Q]" "🚪" "Volver al Menú Principal" "Retornar al menú principal de KubeOps"

        printf "\n  ${CLR_BOLD_WHITE}Seleccione una opción${CLR_RESET} › "
        read -r choice

        case "${choice}" in
            1) clear; deploy_storage_class; pause ;;
            2) clear; deploy_argocd; pause ;;
            3) clear; deploy_velero; pause ;;
            [aA]) 
                clear
                deploy_storage_class
                deploy_argocd
                deploy_velero
                pause ;;
            [qQ]) break ;;
            *) printf "\n  Opción inválida: '%s'\n" "${choice}"; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_gitops_resilience_menu "$@"
fi

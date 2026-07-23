#!/usr/bin/env bash
# devops_toolkit.sh — Orquestador Unificado DevOps / SRE
# ========================================================
# Menú interactivo que encadena:
#   audit_environment.py  → Auditoría completa del clúster
#   yaml_builder.py       → Gestión de manifiestos cluster-aware
#   auto_deploy.py        → Despliegue automático con rollback
#   remediator_advanced.py → Remediación modular
#
# Uso: bash devops_toolkit.sh [--namespace NS] [--dry-run]

set -euo pipefail

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;91m'
GREEN='\033[0;92m'
YELLOW='\033[0;93m'
BLUE='\033[0;94m'
CYAN='\033[0;96m'
WHITE='\033[0;97m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Configuración por defecto ────────────────────────────────────────────────
NAMESPACE=""
DRY_RUN=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AUDIT_SCRIPT="$SCRIPT_DIR/audit_environment.py"
YAML_BUILDER="$SCRIPT_DIR/yaml_builder.py"
AUTO_DEPLOY="$SCRIPT_DIR/auto_deploy.py"
REMEDIATOR="$SCRIPT_DIR/remediator_advanced.py"

# ─── Parsear argumentos de línea de comando ───────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace|-n)
            NAMESPACE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="--dry-run"
            shift
            ;;
        --help|-h)
            echo "Uso: bash devops_toolkit.sh [--namespace NS] [--dry-run]"
            exit 0
            ;;
        *)
            echo "Argumento desconocido: $1"
            exit 1
            ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_err()  { echo -e "  ${RED}✗${NC} $1" >&2; }
log_warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
log_info() { echo -e "  ${BLUE}→${NC} $1"; }

pause() {
    echo ""
    read -rp "  Presiona [ENTER] para continuar..." _
}

check_python() {
    if ! command -v python3 &>/dev/null; then
        log_err "Python 3 no encontrado. Instálalo antes de continuar."
        exit 1
    fi
}

check_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        log_err "kubectl no encontrado en PATH."
        exit 1
    fi
    if ! kubectl cluster-info --request-timeout=5s &>/dev/null; then
        log_warn "No se puede conectar al clúster. Verifica tu kubeconfig."
        return 1
    fi
    return 0
}

check_script() {
    local script="$1"
    if [[ ! -f "$script" ]]; then
        log_err "Script no encontrado: $script"
        return 1
    fi
    return 0
}

ns_flag() {
    if [[ -n "$NAMESPACE" ]]; then
        echo "--namespace $NAMESPACE"
    else
        echo ""
    fi
}

# ─── Banner ───────────────────────────────────────────────────────────────────
show_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║      DevOps Toolkit — SENIAT Kubernetes Cluster         ║"
    echo "  ║      Audit · YAML · Deploy · Remediate · Manage         ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Estado rápido del clúster
    if command -v kubectl &>/dev/null 2>&1; then
        local nodes ready
        nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
        ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "?")
        echo -e "  ${DIM}Clúster: ${nodes} nodos | Ready: ${ready}${NC}"
        if [[ -n "$NAMESPACE" ]]; then
            echo -e "  ${DIM}Namespace activo: ${NAMESPACE}${NC}"
        fi
        if [[ -n "$DRY_RUN" ]]; then
            echo -e "  ${YELLOW}⚠  Modo DRY-RUN activo${NC}"
        fi
    else
        echo -e "  ${YELLOW}⚠  kubectl no disponible${NC}"
    fi
    echo ""
}

# ─── SUBMENÚ: YAML Builder ────────────────────────────────────────────────────
menu_yaml() {
    while true; do
        show_banner
        echo -e "  ${BOLD}${WHITE}[ GESTIONAR MANIFIESTOS YAML ]${NC}\n"
        echo "    1. Inspeccionar recursos actuales del clúster"
        echo "    2. Analizar carencias vs best practices"
        echo "    3. Generar manifiestos correctivos (todos los tipos)"
        echo "    4. Generar solo HPAs"
        echo "    5. Generar solo PDBs"
        echo "    6. Generar solo NetworkPolicies"
        echo "    7. Crear nuevo recurso (modo interactivo)"
        echo "    8. Ver diff antes de aplicar (from-dir ./manifests)"
        echo "    9. Aplicar manifiestos desde ./manifests/"
        echo "    0. Volver al menú principal"
        echo ""
        read -rp "  Selecciona una opción [0-9]: " opt

        check_script "$YAML_BUILDER" || { pause; continue; }
        local ns_arg; ns_arg="$(ns_flag)"

        case "$opt" in
            1)
                echo ""
                python3 "$YAML_BUILDER" inspect $ns_arg
                pause
                ;;
            2)
                echo ""
                python3 "$YAML_BUILDER" analyze $ns_arg
                pause
                ;;
            3)
                echo ""
                python3 "$YAML_BUILDER" generate $ns_arg --type all --output ./manifests/
                pause
                ;;
            4)
                echo ""
                python3 "$YAML_BUILDER" generate $ns_arg --type hpa --output ./manifests/
                pause
                ;;
            5)
                echo ""
                python3 "$YAML_BUILDER" generate $ns_arg --type pdb --output ./manifests/
                pause
                ;;
            6)
                echo ""
                python3 "$YAML_BUILDER" generate $ns_arg --type networkpolicy --output ./manifests/
                pause
                ;;
            7)
                echo ""
                python3 "$YAML_BUILDER" new --interactive --output ./manifests/
                pause
                ;;
            8)
                echo ""
                python3 "$YAML_BUILDER" diff --from-dir ./manifests/
                pause
                ;;
            9)
                echo ""
                python3 "$YAML_BUILDER" apply --from-dir ./manifests/ $DRY_RUN
                pause
                ;;
            0) break ;;
            *) log_warn "Opción inválida" ;;
        esac
    done
}

# ─── SUBMENÚ: Deploy ──────────────────────────────────────────────────────────
menu_deploy() {
    while true; do
        show_banner
        echo -e "  ${BOLD}${WHITE}[ DESPLEGAR MANIFIESTOS ]${NC}\n"
        echo "    1. Ver estado de Deployments"
        echo "    2. Desplegar archivo YAML específico"
        echo "    3. Desplegar todos los manifiestos de ./manifests/"
        echo "    4. Desplegar con rollback automático"
        echo "    5. Rollback manual de un Deployment"
        echo "    0. Volver al menú principal"
        echo ""
        read -rp "  Selecciona una opción [0-5]: " opt

        check_script "$AUTO_DEPLOY" || { pause; continue; }
        local ns_arg; ns_arg="$(ns_flag)"

        case "$opt" in
            1)
                echo ""
                python3 "$AUTO_DEPLOY" --status $ns_arg
                pause
                ;;
            2)
                read -rp "  Ruta del archivo YAML: " yaml_file
                echo ""
                python3 "$AUTO_DEPLOY" --file "$yaml_file" $DRY_RUN
                pause
                ;;
            3)
                echo ""
                python3 "$AUTO_DEPLOY" --from-dir ./manifests/ $DRY_RUN
                pause
                ;;
            4)
                read -rp "  Ruta del archivo YAML: " yaml_file
                echo ""
                python3 "$AUTO_DEPLOY" --file "$yaml_file" --auto-rollback $DRY_RUN
                pause
                ;;
            5)
                read -rp "  Nombre del Deployment: " dep_name
                read -rp "  Namespace: " dep_ns
                echo ""
                python3 "$AUTO_DEPLOY" --rollback --name "$dep_name" --namespace "$dep_ns"
                pause
                ;;
            0) break ;;
            *) log_warn "Opción inválida" ;;
        esac
    done
}

# ─── SUBMENÚ: Remediador ──────────────────────────────────────────────────────
menu_remediate() {
    while true; do
        show_banner
        echo -e "  ${BOLD}${WHITE}[ REMEDIAR HALLAZGOS DEL CLÚSTER ]${NC}\n"
        echo "    1.  Escanear estado actual del clúster"
        echo "    2.  Listar módulos disponibles"
        echo "    3.  [hpa]           Crear HPAs faltantes"
        echo "    4.  [pdb]           Crear PDBs faltantes"
        echo "    5.  [networkpolicy] Crear NetworkPolicies"
        echo "    6.  [resources]     Agregar resource requests/limits"
        echo "    7.  [replicas]      Escalar Deployments con réplica única"
        echo "    8.  [strategy]      Migrar Recreate → RollingUpdate"
        echo "    9.  [rbac]          Revisar cluster-admin en ServiceAccounts"
        echo "    10. [podsecurity]   Parchar securityContext"
        echo "    11. [affinity]      Agregar podAntiAffinity"
        echo "    12. [ephemeral]     Agregar ephemeral-storage limits"
        echo "    13. [certificates]  Guía renovación de certificados"
        echo "    14. [docker-cleanup] Limpiar imágenes huérfanas"
        echo "    15. [all]           Ejecutar TODOS los módulos (con confirmación)"
        echo "    0.  Volver al menú principal"
        echo ""
        read -rp "  Selecciona una opción [0-15]: " opt

        check_script "$REMEDIATOR" || { pause; continue; }
        local ns_arg; ns_arg="$(ns_flag)"

        run_module() {
            local mod="$1"
            echo ""
            python3 "$REMEDIATOR" --module "$mod" $ns_arg $DRY_RUN
            pause
        }

        case "$opt" in
            1)  echo ""; python3 "$REMEDIATOR" --scan $ns_arg; pause ;;
            2)  echo ""; python3 "$REMEDIATOR" --list-modules; pause ;;
            3)  run_module hpa ;;
            4)  run_module pdb ;;
            5)  run_module networkpolicy ;;
            6)  run_module resources ;;
            7)  run_module replicas ;;
            8)  run_module strategy ;;
            9)  run_module rbac ;;
            10) run_module podsecurity ;;
            11) run_module affinity ;;
            12) run_module ephemeral ;;
            13) echo ""; python3 "$REMEDIATOR" --module certificates $DRY_RUN; pause ;;
            14) echo ""; python3 "$REMEDIATOR" --module docker-cleanup $DRY_RUN; pause ;;
            15)
                echo ""
                log_warn "Esto ejecutará TODOS los módulos de remediación en orden de prioridad."
                log_warn "Se pedirá confirmación para cada acción (a menos que uses --dry-run)."
                read -rp "  ¿Continuar? [y/N]: " conf
                if [[ "${conf,,}" == "y" || "${conf,,}" == "yes" ]]; then
                    python3 "$REMEDIATOR" --module all $ns_arg $DRY_RUN
                fi
                pause
                ;;
            0) break ;;
            *) log_warn "Opción inválida" ;;
        esac
    done
}

# ─── FLUJO COMPLETO ───────────────────────────────────────────────────────────
run_full_flow() {
    show_banner
    echo -e "  ${BOLD}${CYAN}[ FLUJO COMPLETO: Audit → Scan → Remediar → Validar ]${NC}\n"
    echo -e "  ${YELLOW}Este flujo ejecutará (en orden):"
    echo "    1. Auditoría completa del clúster (genera sre_audit_report.json)"
    echo "    2. Escaneo de estado por namespace"
    echo "    3. Remediación en modo dry-run (previsualización)"
    echo "    4. Confirmación para aplicar remediaciones"
    echo -e "    5. Segunda auditoría para verificar mejoras${NC}\n"

    read -rp "  ¿Iniciar el flujo completo? [y/N]: " conf
    [[ "${conf,,}" != "y" && "${conf,,}" != "yes" ]] && return

    # Paso 1: Auditoría
    if check_script "$AUDIT_SCRIPT"; then
        echo -e "\n  ${BOLD}PASO 1/5: Auditoría inicial${NC}"
        python3 "$AUDIT_SCRIPT" -o sre_audit_report -f all 2>&1 | tail -20
        log_ok "Auditoría completada → sre_audit_report.json"
    fi

    # Paso 2: Scan
    echo -e "\n  ${BOLD}PASO 2/5: Escaneo del clúster${NC}"
    python3 "$REMEDIATOR" --scan $(ns_flag)
    pause

    # Paso 3: Dry-run de remediación
    echo -e "\n  ${BOLD}PASO 3/5: Previsualización de remediaciones (dry-run)${NC}"
    python3 "$REMEDIATOR" --module all $(ns_flag) --dry-run
    pause

    # Paso 4: Aplicar remediaciones
    read -rp "  ¿Aplicar las remediaciones? [y/N]: " apply_conf
    if [[ "${apply_conf,,}" == "y" || "${apply_conf,,}" == "yes" ]]; then
        echo -e "\n  ${BOLD}PASO 4/5: Aplicando remediaciones${NC}"
        python3 "$REMEDIATOR" --module all $(ns_flag)
        pause
    else
        log_info "Remediaciones omitidas"
    fi

    # Paso 5: Segunda auditoría
    if check_script "$AUDIT_SCRIPT"; then
        echo -e "\n  ${BOLD}PASO 5/5: Auditoría post-remediación${NC}"
        python3 "$AUDIT_SCRIPT" -o sre_audit_report_post -f all 2>&1 | tail -20
        log_ok "Auditoría post-remediación completada → sre_audit_report_post.json"
    fi

    log_ok "Flujo completo finalizado"
    pause
}

# ─── MENÚ PRINCIPAL ───────────────────────────────────────────────────────────
main_menu() {
    check_python

    while true; do
        show_banner
        echo -e "  ${BOLD}${WHITE}MENÚ PRINCIPAL${NC}\n"
        echo "    1. Auditoría Completa del Clúster"
        echo "    2. Gestionar Manifiestos YAML"
        echo "    3. Desplegar Manifiesto"
        echo "    4. Remediar Hallazgos del Clúster"
        echo "    5. Flujo Completo: Audit → Remediar → Validar"
        echo "    6. Configurar Namespace activo"
        echo "    7. Alternar modo Dry-Run"
        echo "    0. Salir"
        echo ""
        if [[ -n "$NAMESPACE" ]]; then
            echo -e "  ${DIM}Namespace activo: ${NAMESPACE}${NC}"
        fi
        if [[ -n "$DRY_RUN" ]]; then
            echo -e "  ${YELLOW}⚠  Modo DRY-RUN: ON${NC}"
        fi
        echo ""
        read -rp "  Selecciona una opción [0-7]: " choice

        case "$choice" in
            1)
                if check_script "$AUDIT_SCRIPT"; then
                    echo ""
                    python3 "$AUDIT_SCRIPT" -o sre_audit_report -f all
                    log_ok "Reporte generado: sre_audit_report.json / sre_audit_report.md"
                fi
                pause
                ;;
            2) menu_yaml ;;
            3) menu_deploy ;;
            4) menu_remediate ;;
            5) run_full_flow ;;
            6)
                read -rp "  Namespace (vacío = todos): " new_ns
                NAMESPACE="$new_ns"
                log_ok "Namespace configurado: '${NAMESPACE:-todos}'"
                sleep 1
                ;;
            7)
                if [[ -n "$DRY_RUN" ]]; then
                    DRY_RUN=""
                    log_warn "Modo DRY-RUN: OFF — Los cambios SE APLICARÁN"
                else
                    DRY_RUN="--dry-run"
                    log_ok "Modo DRY-RUN: ON — Los cambios solo se simularán"
                fi
                sleep 1
                ;;
            0)
                echo -e "\n  ${GREEN}Hasta luego.${NC}\n"
                exit 0
                ;;
            *) log_warn "Opción inválida" ;;
        esac
    done
}

# ─── Punto de entrada ─────────────────────────────────────────────────────────
main_menu

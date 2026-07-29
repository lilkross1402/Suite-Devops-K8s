#!/usr/bin/env bash
# =============================================================================
# KubeOps-Suite :: lib/slo_tracker.sh
# Purpose : Lightweight SLO tracking via structured log events.
#           Tracks operation start/end, duration, status, and error rate.
#           Zero external dependencies — persists to state file and log.
#           Designed to feed Loki/Prometheus via the structured JSONL log.
#
# Usage   : source "${SUITE_ROOT}/lib/slo_tracker.sh"
#           op_id=$(slo_begin_operation "module_master")
#           ... ejecutar operacion ...
#           slo_end_operation "${op_id}" "success" "kubeadm_init completado"
#
# Author  : KubeOps-Suite SRE Hardening (sre/reliability-hardening)
# =============================================================================
if [[ -n "${_SLO_TRACKER_SH_LOADED:-}" ]]; then
    return 0
fi
_SLO_TRACKER_SH_LOADED=true

# Ensure logger and state_manager are available
if ! declare -f log_info &>/dev/null; then
    source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"
fi
if ! declare -f state_set_meta &>/dev/null; then
    source "$(dirname "${BASH_SOURCE[0]}")/state_manager.sh"
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# Porcentaje máximo de operaciones fallidas antes de emitir alerta de budget
readonly SLO_ERROR_BUDGET_THRESHOLD="${SLO_ERROR_BUDGET_THRESHOLD:-10}"

# ---------------------------------------------------------------------------
# slo_begin_operation OP_NAME
# Registra el inicio de una operación crítica.
# Retorna el operation ID que debe pasarse a slo_end_operation.
# ---------------------------------------------------------------------------
slo_begin_operation() {
    local op_name="${1:-unknown}"
    local op_id="${op_name}-$(date +%s%3N)-$$"

    # Exportar correlation ID para que el logger lo incluya en cada línea
    export KUBEOPS_OPERATION_ID="${op_id}"
    export KUBEOPS_MODULE="${op_name}"

    local start_ts
    start_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    state_set_meta "op_${op_id}_name"  "${op_name}"  2>/dev/null || true
    state_set_meta "op_${op_id}_start" "${start_ts}" 2>/dev/null || true
    state_set_meta "op_${op_id}_status" "running"    2>/dev/null || true

    log_info "SLO_EVENT op_start op_id=${op_id} op=${op_name} ts=${start_ts}"
    echo "${op_id}"
}

# ---------------------------------------------------------------------------
# slo_end_operation OP_ID STATUS [DETAIL]
# Registra el fin de una operación y calcula su duración.
# STATUS: "success" | "failure"
# ---------------------------------------------------------------------------
slo_end_operation() {
    local op_id="${1}"
    local status="${2:-success}"
    local detail="${3:-}"

    local end_ts end_epoch start_ts start_epoch duration_ms
    end_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    end_epoch=$(date +%s%3N)

    # Recuperar timestamp de inicio desde state para calcular duración
    local start_ts_raw
    start_ts_raw=$(state_get_meta "op_${op_id}_start" 2>/dev/null || echo "")
    if [[ -n "${start_ts_raw}" && "${start_ts_raw}" != "null" ]]; then
        # Intentar parsear timestamp (compatible con GNU date)
        local start_epoch
        start_epoch=$(date -u -d "${start_ts_raw}" +%s%3N 2>/dev/null || \
                      date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${start_ts_raw}" +%s%3N 2>/dev/null || \
                      echo "${end_epoch}")
        duration_ms=$(( end_epoch - start_epoch ))
    else
        duration_ms=-1
    fi

    state_set_meta "op_${op_id}_end"      "${end_ts}"       2>/dev/null || true
    state_set_meta "op_${op_id}_status"   "${status}"       2>/dev/null || true
    state_set_meta "op_${op_id}_duration" "${duration_ms}"  2>/dev/null || true

    if [[ "${status}" == "success" ]]; then
        local dur_str="${duration_ms}ms"
        [[ "${duration_ms}" -gt 60000 ]] && dur_str="$(( duration_ms / 1000 ))s"
        log_success "SLO_EVENT op_end op_id=${op_id} status=success duration=${dur_str} detail=${detail:-ok}"
        log_info "METRIC kubeops_op_duration_ms{op=\"${op_id%%\-*}\",status=\"success\"} ${duration_ms}"
    else
        log_error  "SLO_EVENT op_end op_id=${op_id} status=failure duration=${duration_ms}ms detail=${detail:-sin_detalle}"
        log_info   "METRIC kubeops_op_duration_ms{op=\"${op_id%%\-*}\",status=\"failure\"} ${duration_ms}"
        # Verificar error budget tras cada fallo
        _slo_check_error_budget "${op_id}"
    fi

    # Limpiar correlation ID del entorno
    unset KUBEOPS_OPERATION_ID KUBEOPS_MODULE
}

# ---------------------------------------------------------------------------
# slo_timed_operation OP_NAME CMD [ARGS...]
# Convenience wrapper: corre CMD y registra automáticamente inicio/fin.
# Retorna el exit code del CMD.
# ---------------------------------------------------------------------------
slo_timed_operation() {
    local op_name="${1}"; shift
    local op_id
    op_id=$(slo_begin_operation "${op_name}")

    if "${@}"; then
        slo_end_operation "${op_id}" "success"
        return 0
    else
        local exit_code=$?
        slo_end_operation "${op_id}" "failure" "exit_code=${exit_code}"
        return "${exit_code}"
    fi
}

# ---------------------------------------------------------------------------
# _slo_check_error_budget [TRIGGERING_OP_ID]
# Calcula la tasa de error de las últimas operaciones guardadas en el state
# y emite advertencia si supera el umbral definido en SLO_ERROR_BUDGET_THRESHOLD.
# ---------------------------------------------------------------------------
_slo_check_error_budget() {
    local triggering_op="${1:-unknown}"

    if ! command -v jq &>/dev/null || [[ ! -f "${KUBEOPS_STATE_FILE:-}" ]]; then
        return 0
    fi

    local total_ops failed_ops
    total_ops=$(jq '[.metadata | to_entries[]
                    | select(.key | test("op_.*_status"))
                    | select(.value != "running")] | length' \
                "${KUBEOPS_STATE_FILE}" 2>/dev/null || echo "0")

    failed_ops=$(jq '[.metadata | to_entries[]
                    | select(.key | test("op_.*_status"))
                    | select(.value == "failure")] | length' \
                "${KUBEOPS_STATE_FILE}" 2>/dev/null || echo "0")

    if [[ "${total_ops}" -eq 0 ]]; then
        return 0
    fi

    local error_rate=$(( (failed_ops * 100) / total_ops ))

    log_info "SLO_METRIC error_rate=${error_rate}% failed=${failed_ops}/${total_ops} trigger=${triggering_op}"
    log_info "METRIC kubeops_error_rate_pct ${error_rate}"

    if [[ "${error_rate}" -gt "${SLO_ERROR_BUDGET_THRESHOLD}" ]]; then
        log_warn "═══════════════════════════════════════════════════════════════"
        log_warn "  ⚠  ERROR BUDGET ALERT"
        log_warn "  Tasa de fallo actual : ${error_rate}%"
        log_warn "  Umbral SLO           : ${SLO_ERROR_BUDGET_THRESHOLD}%"
        log_warn "  Operaciones fallidas : ${failed_ops} de ${total_ops} totales"
        log_warn "  Acción recomendada   : Pausar despliegues y revisar logs"
        log_warn "  Logs estructurados   : ${KUBEOPS_LOG_DIR:-~/.kubeops/logs}/*.jsonl"
        log_warn "═══════════════════════════════════════════════════════════════"
    fi
}

# ---------------------------------------------------------------------------
# slo_show_summary
# Muestra un resumen de operaciones registradas en el state file.
# ---------------------------------------------------------------------------
slo_show_summary() {
    if ! command -v jq &>/dev/null || [[ ! -f "${KUBEOPS_STATE_FILE:-}" ]]; then
        log_warn "jq o state file no disponible — no se puede mostrar resumen SLO"
        return 0
    fi

    log_section "Resumen de Operaciones SRE (SLO Tracking)"

    local total failed success running
    total=$(jq '[.metadata | to_entries[] | select(.key | test("op_.*_status"))] | length' \
            "${KUBEOPS_STATE_FILE}" 2>/dev/null || echo "0")
    success=$(jq '[.metadata | to_entries[] | select(.key | test("op_.*_status")) | select(.value == "success")] | length' \
              "${KUBEOPS_STATE_FILE}" 2>/dev/null || echo "0")
    failed=$(jq '[.metadata | to_entries[] | select(.key | test("op_.*_status")) | select(.value == "failure")] | length' \
             "${KUBEOPS_STATE_FILE}" 2>/dev/null || echo "0")
    running=$(jq '[.metadata | to_entries[] | select(.key | test("op_.*_status")) | select(.value == "running")] | length' \
              "${KUBEOPS_STATE_FILE}" 2>/dev/null || echo "0")

    local error_rate=0
    [[ "${total}" -gt 0 ]] && error_rate=$(( (failed * 100) / total ))

    printf "\n"
    printf "  %-28s %s\n"  "Total operaciones:"    "${total}"
    printf "  %-28s ${CLR_BOLD_GREEN}%s${CLR_RESET}\n" "Exitosas:" "${success}"
    printf "  %-28s ${CLR_BOLD_RED}%s${CLR_RESET}\n"   "Fallidas:" "${failed}"
    printf "  %-28s %s\n"  "En progreso:"           "${running}"
    printf "  %-28s " "Tasa de error:"
    if [[ "${error_rate}" -gt "${SLO_ERROR_BUDGET_THRESHOLD}" ]]; then
        printf "${CLR_BOLD_RED}%d%% ⚠ (supera umbral %d%%)${CLR_RESET}\n" \
            "${error_rate}" "${SLO_ERROR_BUDGET_THRESHOLD}"
    else
        printf "${CLR_BOLD_GREEN}%d%%${CLR_RESET} (umbral: %d%%)\n" \
            "${error_rate}" "${SLO_ERROR_BUDGET_THRESHOLD}"
    fi
    printf "\n"
}

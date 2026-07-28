#!/usr/bin/env python3
"""
KAgent SRE Autonomous Controller & Interactive Telegram Bot
===========================================================
Control loop continuo, resiliente y autónomo para autogestión de Kubernetes.
Incluye:
- Monitoreo de Nodos y Cordoning preventivo ante condiciones de presión.
- Auto-remediación de Pods en CrashLoopBackOff, ImagePullBackOff, Evicted, Pending prolongado.
- Análisis Inteligente de Logs (OOMKilled, Database Connection Failures, Stack Traces).
- Backoff Exponencial y Reconexión Automática ante fallos del API Server.
- Notificaciones proactivas a Telegram y Bot Interactivo para consultas, comandos y remediación remota.
"""

import os
import re
import sys
import time
import json
import logging
import threading
import urllib.request
import urllib.parse
from typing import Dict, List, Optional, Tuple, Any
from functools import wraps

from kubernetes import client, config, watch
from kubernetes.client.rest import ApiException

# -----------------------------------------------------------------------------
# Configuración de Logging
# -----------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("kagent-sre")

# -----------------------------------------------------------------------------
# Constantes y Variables de Entorno
# -----------------------------------------------------------------------------
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
TELEGRAM_ALLOWED_USER_IDS = os.environ.get("TELEGRAM_ALLOWED_USER_IDS", "").strip()
CHECK_INTERVAL_SECONDS = int(os.environ.get("CHECK_INTERVAL_SECONDS", "15"))
PENDING_THRESHOLD_MINUTES = int(os.environ.get("PENDING_THRESHOLD_MINUTES", "10"))
MAX_RETRIES = 5
INITIAL_BACKOFF_SECONDS = 2.0
MAX_BACKOFF_SECONDS = 60.0

# Parsing de Usuarios / ChatIDs Autorizados
ALLOWED_USERS = set()
if TELEGRAM_CHAT_ID:
    for cid in TELEGRAM_CHAT_ID.replace(",", " ").split():
        if cid.strip():
            ALLOWED_USERS.add(cid.strip())
if TELEGRAM_ALLOWED_USER_IDS:
    for uid in TELEGRAM_ALLOWED_USER_IDS.replace(",", " ").split():
        if uid.strip():
            ALLOWED_USERS.add(uid.strip())

# Patrones Críticos para Análisis de Logs
CRITICAL_LOG_PATTERNS = {
    "OOMKilled": r"(OOMKilled|Out of memory|killed process|Memory limit exceeded)",
    "DatabaseConnection": r"(Connection refused|Cannot connect to database|FATAL: database|ECONNREFUSED|PG::ConnectionBad|MongoNetworkError)",
    "AuthenticationError": r"(Unauthorized|AccessDenied|401 Unauthorized|403 Forbidden|Invalid credentials)",
    "StorageError": r"(No space left on device|Read-only file system|DiskFull|IOError)",
    "UnhandledException": r"(Panic:|NullPointerException|Fatal error|Segmentation fault|SIGSEGV|Traceback \(most recent call last\))"
}

# -----------------------------------------------------------------------------
# Decorador de Exponential Backoff & Resilience
# -----------------------------------------------------------------------------
def with_exponential_backoff(max_retries: int = MAX_RETRIES, initial_delay: float = INITIAL_BACKOFF_SECONDS):
    """Decorador para llamadas a la API de Kubernetes con reintento ante fallos transitorios."""
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            delay = initial_delay
            for attempt in range(1, max_retries + 1):
                try:
                    return func(*args, **kwargs)
                except ApiException as e:
                    if e.status in [429, 500, 502, 503, 504]:
                        logger.warning(f"⚠️ API Server Error HTTP {e.status} en '{func.__name__}'. Reintento {attempt}/{max_retries} en {delay:.1f}s...")
                    elif e.status == 404:
                        raise e
                    else:
                        logger.error(f"Error de API k8s HTTP {e.status} en '{func.__name__}': {e.reason}")
                        raise e
                except Exception as ex:
                    logger.warning(f"⚠️ Excepción de red en '{func.__name__}': {ex}. Reintento {attempt}/{max_retries} en {delay:.1f}s...")
                
                time.sleep(delay)
                delay = min(delay * 2.0, MAX_BACKOFF_SECONDS)
            raise RuntimeError(f"Operación '{func.__name__}' falló tras {max_retries} reintentos.")
        return wrapper
    return decorator

# -----------------------------------------------------------------------------
# Envío de Mensajes a Telegram
# -----------------------------------------------------------------------------
def send_telegram_alert(message: str, chat_id: Optional[str] = None) -> None:
    """Envía alertas formateadas en Markdown a Telegram."""
    target_chat = chat_id or TELEGRAM_CHAT_ID
    if not TELEGRAM_BOT_TOKEN or not target_chat:
        logger.debug("Telegram credentials no configuradas. Omitiendo envío de alerta.")
        return

    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    chunks = [message[i:i+4000] for i in range(0, len(message), 4000)]
    
    for chunk in chunks:
        payload = urllib.parse.urlencode({"chat_id": target_chat, "text": chunk, "parse_mode": "Markdown"}).encode("utf-8")
        req = urllib.request.Request(url, data=payload)
        try:
            with urllib.request.urlopen(req, timeout=10):
                pass
        except Exception:
            payload_plain = urllib.parse.urlencode({"chat_id": target_chat, "text": chunk}).encode("utf-8")
            req_plain = urllib.request.Request(url, data=payload_plain)
            try:
                with urllib.request.urlopen(req_plain, timeout=10):
                    pass
            except Exception as e:
                logger.error(f"Error al enviar notificación Telegram: {e}")

# -----------------------------------------------------------------------------
# Clase Principal del Controlador SRE
# -----------------------------------------------------------------------------
class KAgentSREController:
    def __init__(self):
        self._init_k8s_client()
        self.node_instability_counter: Dict[str, int] = {}
        logger.info("🚀 KAgent SRE Controller & Telegram Bot inicializado correctamente.")

    def _init_k8s_client(self):
        """Inicializa la configuración de Kubernetes (In-Cluster o Local Kubeconfig)."""
        try:
            config.load_incluster_config()
            logger.info("Cargada configuración In-Cluster de Kubernetes.")
        except config.ConfigException:
            try:
                config.load_kube_config()
                logger.info("Cargada configuración local (~/.kube/config) de Kubernetes.")
            except Exception as e:
                logger.critical(f"No se pudo cargar la configuración de Kubernetes: {e}")
                sys.exit(1)

        self.core_v1 = client.CoreV1Api()
        self.apps_v1 = client.AppsV1Api()

    # -------------------------------------------------------------------------
    # 1. Monitoreo y Gestión de Nodos (Auto-Cordoning)
    # -------------------------------------------------------------------------
    @with_exponential_backoff()
    def list_nodes(self):
        return self.core_v1.list_node()

    @with_exponential_backoff()
    def cordon_node(self, node_name: str) -> bool:
        """Marca un nodo como unschedulable (cordon)."""
        body = {"spec": {"unschedulable": True}}
        try:
            self.core_v1.patch_node(node_name, body)
            logger.warning(f"🔒 Nodo '{node_name}' ha sido marcado como UNSCHEDULABLE (Cordoned).")
            return True
        except ApiException as e:
            logger.error(f"Error al aislar (cordon) nodo '{node_name}': {e}")
            return False

    @with_exponential_backoff()
    def uncordon_node(self, node_name: str) -> bool:
        """Marca un nodo como schedulable (uncordon)."""
        body = {"spec": {"unschedulable": False}}
        try:
            self.core_v1.patch_node(node_name, body)
            logger.info(f"🔓 Nodo '{node_name}' ha sido marcado como SCHEDULABLE (Uncordoned).")
            return True
        except ApiException as e:
            logger.error(f"Error al habilitar nodo '{node_name}': {e}")
            return False

    def inspect_and_remediate_nodes(self):
        """Inspecciona Nodos y aísla preventivamente nodos inestables."""
        try:
            nodes = self.list_nodes()
        except Exception as e:
            logger.error(f"Error consultando lista de nodos: {e}")
            return

        for node in nodes.items:
            name = node.metadata.name
            conditions = {cond.type: cond.status for cond.type in node.status.conditions}
            
            is_ready = conditions.get("Ready") == "True"
            mem_pressure = conditions.get("MemoryPressure") == "True"
            disk_pressure = conditions.get("DiskPressure") == "True"
            pid_pressure = conditions.get("PIDPressure") == "True"

            has_pressure = mem_pressure or disk_pressure or pid_pressure or not is_ready
            
            if has_pressure:
                self.node_instability_counter[name] = self.node_instability_counter.get(name, 0) + 1
                count = self.node_instability_counter[name]
                logger.warning(f"⚠️ Nodo '{name}' presenta inestabilidad ({count}/3). Ready={is_ready}, MemoryPressure={mem_pressure}")

                if count >= 3 and not node.spec.unschedulable:
                    success = self.cordon_node(name)
                    if success:
                        reasons = []
                        if not is_ready: reasons.append("NotReady")
                        if mem_pressure: reasons.append("MemoryPressure")
                        if disk_pressure: reasons.append("DiskPressure")
                        if pid_pressure: reasons.append("PIDPressure")
                        
                        alert = (
                            f"🚨 *ALERTA SRE: AUTO-CORDON APLICADO*\n\n"
                            f"📌 *Nodo:* `{name}`\n"
                            f"⚠️ *Motivo:* Inestabilidad prolongada ({', '.join(reasons)}).\n"
                            f"🛡️ *Acción Autónoma:* Nodo marcado como `Unschedulable` para prevenir desastres."
                        )
                        send_telegram_alert(alert)
            else:
                if name in self.node_instability_counter:
                    logger.info(f"🟢 Nodo '{name}' ha recuperado su estabilidad.")
                    del self.node_instability_counter[name]

    # -------------------------------------------------------------------------
    # 2. Análisis de Logs y Auto-Remediación de Pods
    # -------------------------------------------------------------------------
    @with_exponential_backoff()
    def get_pod_logs(self, pod_name: str, namespace: str, container_name: str, previous: bool = True, tail_lines: int = 150) -> str:
        try:
            return self.core_v1.read_namespaced_pod_log(
                name=pod_name,
                namespace=namespace,
                container=container_name,
                previous=previous,
                tail_lines=tail_lines
            )
        except ApiException as e:
            if previous:
                try:
                    return self.core_v1.read_namespaced_pod_log(
                        name=pod_name,
                        namespace=namespace,
                        container=container_name,
                        previous=False,
                        tail_lines=tail_lines
                    )
                except Exception:
                    pass
            return f"No se pudieron extraer logs para {pod_name}/{container_name}: {e.reason}"

    def analyze_logs(self, raw_logs: str) -> Tuple[List[str], str]:
        detected_categories = []
        snippets = []

        for category, pattern in CRITICAL_LOG_PATTERNS.items():
            matches = re.findall(pattern, raw_logs, re.IGNORECASE)
            if matches:
                detected_categories.append(category)
                for line in raw_logs.splitlines()[-30:]:
                    if re.search(pattern, line, re.IGNORECASE):
                        snippets.append(line.strip())
                        break

        summary_snippet = "\n".join(snippets[:3]) if snippets else "Sin fragmentos claros en las últimas líneas."
        return detected_categories, summary_snippet

    @with_exponential_backoff()
    def list_all_pods(self):
        return self.core_v1.list_pod_for_all_namespaces()

    @with_exponential_backoff()
    def delete_pod(self, pod_name: str, namespace: str) -> bool:
        try:
            self.core_v1.delete_namespaced_pod(
                name=pod_name,
                namespace=namespace,
                body=client.V1DeleteOptions(grace_period_seconds=5)
            )
            logger.info(f"♻️ Pod '{pod_name}' en namespace '{namespace}' eliminado para forzar recreación.")
            return True
        except ApiException as e:
            logger.error(f"Error al eliminar pod '{pod_name}' en '{namespace}': {e}")
            return False

    def inspect_and_remediate_pods(self):
        try:
            pods = self.list_all_pods()
        except Exception as e:
            logger.error(f"Error al listar pods: {e}")
            return

        now = time.time()

        for pod in pods.items:
            ns = pod.metadata.namespace
            name = pod.metadata.name

            if ns == "kagent-system" and "kagent-sre" in name:
                continue

            phase = pod.status.phase
            statuses = pod.status.container_statuses or []
            
            anomalies = []
            should_restart = False
            failing_container = ""
            restart_count = 0

            if pod.status.reason == "Evicted":
                anomalies.append("Evicted (Presión de recursos en nodo)")
                should_restart = True

            if phase == "Pending":
                creation_ts = pod.metadata.creation_timestamp.timestamp()
                pending_duration_min = (now - creation_ts) / 60.0
                if pending_duration_min > PENDING_THRESHOLD_MINUTES:
                    anomalies.append(f"Pending Prolongado ({pending_duration_min:.1f} min)")
                    should_restart = True

            for cs in statuses:
                failing_container = cs.name
                restart_count = cs.restart_count
                waiting = cs.state.waiting
                terminated = cs.state.terminated

                if waiting:
                    reason = waiting.reason
                    if reason in ["CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError"]:
                        anomalies.append(f"Estado: {reason}")
                        if reason == "CrashLoopBackOff" and restart_count >= 3:
                            should_restart = True

                if terminated and terminated.reason == "OOMKilled":
                    anomalies.append("Finalizado por OOMKilled")
                    should_restart = True

            if anomalies:
                logger.warning(f"⚠️ Pod Anómalo Detectado: {ns}/{name} -> {', '.join(anomalies)}")

                logs = self.get_pod_logs(name, ns, failing_container, previous=True) if failing_container else "N/A"
                detected_patterns, log_snippet = self.analyze_logs(logs)

                root_cause = ", ".join(detected_patterns) if detected_patterns else "Causa raíz no identificada automáticamente."

                remediation_action = "Ninguna (Se requiere revisión de imagen o config)"
                if should_restart:
                    success = self.delete_pod(name, ns)
                    if success:
                        remediation_action = "Pod recreado autónomamente por Controller"

                alert_msg = (
                    f"🤖 *KAGENT SRE AUTO-REMEDIACIÓN*\n\n"
                    f"📦 *Pod:* `{ns}/{name}`\n"
                    f"⚠️ *Anomalía:* {', '.join(anomalies)}\n"
                    f"🔄 *Restarts:* `{restart_count}`\n"
                    f"🔍 *Patrones Logs:* `{root_cause}`\n\n"
                    f"📜 *Snippet de Log:* \n```\n{log_snippet}\n```\n"
                    f"🛠️ *Acción Autónoma:* {remediation_action}"
                )
                send_telegram_alert(alert_msg)

    # -------------------------------------------------------------------------
    # 3. Bot Interactivo de Telegram (Comandos y Consultas)
    # -------------------------------------------------------------------------
    def reply_cluster_status(self, chat_id: str):
        try:
            nodes = self.list_nodes().items
            pods = self.list_all_pods().items
            
            ready_nodes = sum(1 for n in nodes if any(c.type == "Ready" and c.status == "True" for c.readiness_status if hasattr(c, "type") and hasattr(c, "status") or hasattr(c, "type")))
            total_nodes = len(nodes)
            
            failing_pods = []
            for p in pods:
                if p.status.phase in ["Failed", "Unknown", "Pending"]:
                    failing_pods.append(f"`{p.metadata.namespace}/{p.metadata.name}` ({p.status.phase})")
                else:
                    for cs in (p.status.container_statuses or []):
                        if cs.state.waiting and cs.state.waiting.reason in ["CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull"]:
                            failing_pods.append(f"`{p.metadata.namespace}/{p.metadata.name}` ({cs.state.waiting.reason})")
                            break

            msg = (
                f"📊 *REPORTE DE ESTADO DEL CLÚSTER KUBERNETES*\n\n"
                f"💻 *Nodos Saludables:* `{total_nodes}/{total_nodes}` Ready\n"
                f"📦 *Total de Pods:* `{len(pods)}` pods en ejecución\n"
                f"🚨 *Pods Anómalos:* `{len(failing_pods)}` pods\n"
            )
            if failing_pods:
                msg += "\n*Lista de Pods con Fallas:*\n" + "\n".join(failing_pods[:10])
                if len(failing_pods) > 10:
                    msg += f"\n_...y {len(failing_pods)-10} pods más._"

            send_telegram_alert(msg, chat_id=chat_id)
        except Exception as e:
            send_telegram_alert(f"❌ Error al consultar estado del clúster: {e}", chat_id=chat_id)

    def reply_nodes_status(self, chat_id: str):
        try:
            nodes = self.list_nodes().items
            lines = []
            for n in nodes:
                name = n.metadata.name
                roles = [k.replace("node-role.kubernetes.io/", "") for k in n.metadata.labels if "node-role" in k]
                role_str = ",".join(roles) if roles else "worker"
                is_ready = any(c.type == "Ready" and c.status == "True" for c.status.conditions for c in [c] if c.type == "Ready")
                status_icon = "🟢 Ready" if is_ready else "🔴 NotReady"
                if n.spec.unschedulable:
                    status_icon += " 🔒 (Cordoned)"
                ip = next((addr.address for addr in n.status.addresses if addr.type == "InternalIP"), "N/A")
                lines.append(f"• `{name}` ({ip}) | *{role_str}* | {status_icon}")

            msg = "🖥️ *ESTADO DE NODOS DEL CLÚSTER:*\n\n" + "\n".join(lines)
            send_telegram_alert(msg, chat_id=chat_id)
        except Exception as e:
            send_telegram_alert(f"❌ Error al consultar nodos: {e}", chat_id=chat_id)

    def reply_pods_status(self, chat_id: str, namespace: Optional[str] = None):
        try:
            if namespace:
                pods = self.core_v1.list_namespaced_pod(namespace).items
            else:
                pods = self.list_all_pods().items

            failing = []
            for p in pods:
                ns = p.metadata.namespace
                name = p.metadata.name
                phase = p.status.phase
                st_reason = phase
                restarts = 0
                for cs in (p.status.container_statuses or []):
                    restarts += cs.restart_count
                    if cs.state.waiting:
                        st_reason = cs.state.waiting.reason

                if st_reason in ["CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "Evicted", "Pending"] or restarts > 5:
                    failing.append(f"• `{ns}/{name}` | *{st_reason}* | Restarts: `{restarts}`")

            if failing:
                msg = f"🚨 *PODS EN ESTADO ANÓMALO ({len(failing)}):*\n\n" + "\n".join(failing[:15])
            else:
                msg = "🟢 *Todos los Pods están funcionando normalmente (Ready / Running).* "

            send_telegram_alert(msg, chat_id=chat_id)
        except Exception as e:
            send_telegram_alert(f"❌ Error al consultar pods: {e}", chat_id=chat_id)

    def reply_pod_logs(self, chat_id: str, pod_target: str):
        try:
            target_ns = None
            target_name = pod_target
            if "/" in pod_target:
                target_ns, target_name = pod_target.split("/", 1)

            pods = self.list_all_pods().items
            matched_pod = None
            for p in pods:
                if target_ns and p.metadata.namespace != target_ns:
                    continue
                if target_name in p.metadata.name:
                    matched_pod = p
                    break

            if not matched_pod:
                send_telegram_alert(f"❌ No se encontró ningún pod coincidente con `{pod_target}`.", chat_id=chat_id)
                return

            ns = matched_pod.metadata.namespace
            name = matched_pod.metadata.name
            container = matched_pod.spec.containers[0].name

            logs = self.get_pod_logs(name, ns, container, previous=True, tail_lines=50)
            categories, snippet = self.analyze_logs(logs)
            
            msg = (
                f"📜 *DIAGNÓSTICO DE LOGS PARA POD:* `{ns}/{name}`\n"
                f"🔍 *Patrones Detectados:* `{', '.join(categories) if categories else 'Ninguno evidente'}`\n\n"
                f"```\n{snippet}\n```"
            )
            send_telegram_alert(msg, chat_id=chat_id)
        except Exception as e:
            send_telegram_alert(f"❌ Error al analizar logs: {e}", chat_id=chat_id)

    def reply_remediate_pod(self, chat_id: str, pod_target: str):
        try:
            target_ns = None
            target_name = pod_target
            if "/" in pod_target:
                target_ns, target_name = pod_target.split("/", 1)

            pods = self.list_all_pods().items
            matched_pod = None
            for p in pods:
                if target_ns and p.metadata.namespace != target_ns:
                    continue
                if target_name in p.metadata.name:
                    matched_pod = p
                    break

            if not matched_pod:
                send_telegram_alert(f"❌ No se encontró pod `{pod_target}` para remediación.", chat_id=chat_id)
                return

            ns = matched_pod.metadata.namespace
            name = matched_pod.metadata.name

            ok = self.delete_pod(name, ns)
            if ok:
                send_telegram_alert(f"🛠️ *REMEDIACIÓN MANUAL EXECUTADA:* Pod `{ns}/{name}` fue eliminado para forzar su recreación limpia por el Controller.", chat_id=chat_id)
            else:
                send_telegram_alert(f"❌ Error al ejecutar remediación en `{ns}/{name}`.", chat_id=chat_id)
        except Exception as e:
            send_telegram_alert(f"❌ Error durante remediación: {e}", chat_id=chat_id)

    def reply_general_query(self, chat_id: str, query: str):
        q = query.lower()
        if "fall" in q or "error" in q or "caida" in q or "caída" in q:
            self.reply_pods_status(chat_id)
        elif "nodo" in q or "node" in q or "servidor" in q:
            self.reply_nodes_status(chat_id)
        else:
            self.reply_cluster_status(chat_id)

    def handle_telegram_message(self, msg: dict):
        user_id = str(msg.get("from", {}).get("id", ""))
        chat_id = str(msg.get("chat", {}).get("id", ""))
        text = msg.get("text", "").strip()

        if ALLOWED_USERS and user_id not in ALLOWED_USERS and chat_id not in ALLOWED_USERS:
            send_telegram_alert(
                f"⛔ *Acceso Denegado*\n\nSu UserID `{user_id}` no está autorizado en KAgent SRE.",
                chat_id=chat_id
            )
            return

        cmd = text.split()[0].lower() if text else ""

        if cmd in ["/start", "/help"]:
            reply = (
                "🤖 *KAgent SRE Autonomous Controller & Interactive Bot*\n\n"
                "📌 *Comandos Disponibles:*\n"
                "• `/status` - Estado general de salud del clúster y pods\n"
                "• `/nodes` - Detalle e inspección de nodos\n"
                "• `/pods [namespace]` - Pods fallando o lista de pods\n"
                "• `/logs <pod>` - Análisis de logs de un pod en problemas\n"
                "• `/remediate <pod>` - Reiniciar pod atascado\n"
                "• `/cordon <nodo>` - Aislar nodo de forma preventiva\n"
                "• `/uncordon <nodo>` - Habilitar nodo para agendamiento\n\n"
                "💬 *También puedes escribir preguntas en lenguaje natural* (ej. _¿qué pods están fallando?_, _estado de nodos_)."
            )
            send_telegram_alert(reply, chat_id=chat_id)

        elif cmd in ["/status", "status"]:
            self.reply_cluster_status(chat_id)

        elif cmd in ["/nodes", "nodes"]:
            self.reply_nodes_status(chat_id)

        elif cmd in ["/pods", "pods"]:
            parts = text.split()
            ns = parts[1] if len(parts) > 1 and not parts[1].startswith("/") else None
            self.reply_pods_status(chat_id, namespace=ns)

        elif cmd in ["/logs", "/log"]:
            parts = text.split()
            if len(parts) > 1:
                self.reply_pod_logs(chat_id, parts[1])
            else:
                send_telegram_alert("⚠️ Uso: `/logs <nombre-del-pod>`", chat_id=chat_id)

        elif cmd in ["/remediate", "/restart", "/remediar", "/reiniciar"]:
            parts = text.split()
            if len(parts) > 1:
                self.reply_remediate_pod(chat_id, parts[1])
            else:
                send_telegram_alert("⚠️ Uso: `/remediate <nombre-del-pod>`", chat_id=chat_id)

        elif cmd == "/cordon":
            parts = text.split()
            if len(parts) > 1:
                ok = self.cordon_node(parts[1])
                res = f"🔒 Nodo `{parts[1]}` marcado como UNSCHEDULABLE." if ok else f"❌ Error aislando nodo `{parts[1]}`."
                send_telegram_alert(res, chat_id=chat_id)
            else:
                send_telegram_alert("⚠️ Uso: `/cordon <nombre-del-nodo>`", chat_id=chat_id)

        elif cmd == "/uncordon":
            parts = text.split()
            if len(parts) > 1:
                ok = self.uncordon_node(parts[1])
                res = f"🔓 Nodo `{parts[1]}` habilitado (SCHEDULABLE)." if ok else f"❌ Error habilitando nodo `{parts[1]}`."
                send_telegram_alert(res, chat_id=chat_id)
            else:
                send_telegram_alert("⚠️ Uso: `/uncordon <nombre-del-nodo>`", chat_id=chat_id)

        else:
            self.reply_general_query(chat_id, text)

    def run_telegram_bot_loop(self):
        if not TELEGRAM_BOT_TOKEN:
            logger.warning("TELEGRAM_BOT_TOKEN no configurado. El bot interactivo de Telegram no se iniciará.")
            return

        logger.info("🤖 Iniciando Bot Interactivo de Telegram (Long-Polling)...")
        offset = 0
        while True:
            try:
                url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/getUpdates?offset={offset}&timeout=20"
                req = urllib.request.Request(url)
                with urllib.request.urlopen(req, timeout=25) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                    if data.get("ok"):
                        for result in data.get("result", []):
                            offset = result["update_id"] + 1
                            msg = result.get("message")
                            if msg and "text" in msg:
                                self.handle_telegram_message(msg)
            except Exception as e:
                time.sleep(5)

    # -------------------------------------------------------------------------
    # 4. Continuous Resilient Control Loop & Dual Threading
    # -------------------------------------------------------------------------
    def run_control_loop(self):
        logger.info("🔄 Iniciando Bucle de Control Autónomo SRE de KAgent...")
        send_telegram_alert("🟢 *KAgent SRE Controller Activo:* Monitoreo autónomo, auto-remediación continua y bot interactivo habilitados en el clúster.")
        
        # Hilo 2: Bot Interactivo de Telegram
        bot_thread = threading.Thread(target=self.run_telegram_bot_loop, daemon=True)
        bot_thread.start()

        while True:
            try:
                self.inspect_and_remediate_nodes()
                self.inspect_and_remediate_pods()
            except Exception as e:
                logger.error(f"❌ Error inesperado en el bucle de control SRE: {e}", exc_info=True)
                time.sleep(5)

            time.sleep(CHECK_INTERVAL_SECONDS)

# -----------------------------------------------------------------------------
# Punto de Entrada Principal
# -----------------------------------------------------------------------------
if __name__ == "__main__":
    controller = KAgentSREController()
    controller.run_control_loop()

#!/usr/bin/env python3
"""
remediator_advanced.py — Remediador Modular Kubernetes Cluster-Aware
====================================================================
Descubre el estado real del clúster, muestra hallazgos y aplica correcciones
de forma modular, segura y con registro de auditoría.

Módulos disponibles:
  hpa           → Crear HPAs para Deployments sin escalado automático
  pdb           → Crear PDBs para Deployments sin protección a disrupciones
  networkpolicy → Generar NetworkPolicy deny-all + allow por namespace
  resources     → Parchar resources requests/limits en Deployments
  replicas      → Escalar a mínimo 2 los Deployments con réplica única
  strategy      → Migrar Recreate → RollingUpdate
  rbac          → Revisar y remediar ServiceAccounts con cluster-admin
  docker-cleanup → Limpiar imágenes Docker huérfanas (dangling)
  certificates  → Guía interactiva para renovar certificados expirados
  podsecurity   → Parchar securityContext en contenedores
  affinity      → Agregar podAntiAffinity soft a Deployments
  ephemeral     → Agregar límites de ephemeral-storage
  all           → Ejecutar todos los módulos en orden de prioridad

Uso:
  python3 remediator_advanced.py --scan
  python3 remediator_advanced.py --module hpa --dry-run
  python3 remediator_advanced.py --module all --namespace servicios-declaracion
  python3 remediator_advanced.py --module all --auto-approve
  python3 remediator_advanced.py --list-modules
"""

import argparse
import datetime
import json
import os
import subprocess
import sys
import time

# ─── Colores ──────────────────────────────────────────────────────────────────
class C:
    RESET  = "\033[0m"
    BOLD   = "\033[1m"
    RED    = "\033[91m"
    GREEN  = "\033[92m"
    YELLOW = "\033[93m"
    BLUE   = "\033[94m"
    CYAN   = "\033[96m"
    WHITE  = "\033[97m"
    DIM    = "\033[2m"
    MAGENTA = "\033[95m"

# Namespaces de sistema — nunca se tocan automáticamente
SYSTEM_NAMESPACES = {
    "kube-system", "kube-public", "kube-node-lease",
    "calico-system", "calico-apiserver", "tigera-operator",
    "metallb-system", "lens-metrics", "cert-manager",
}

# Contenedores que REQUIEREN privileged por diseño (CNI / sistema)
PRIVILEGED_WHITELIST = {
    "calico-node", "flexvol-driver", "install-cni",
    "calico-csi", "csi-node-driver-registrar", "kube-proxy",
}

MODULE_PRIORITY_ORDER = [
    "certificates",   # Urgente: cert expirado
    "rbac",           # Urgente: cluster-admin
    "replicas",       # Alta: SPOF
    "strategy",       # Alta: downtime en deploy
    "resources",      # Media: QoS / scheduler
    "ephemeral",      # Media: DiskPressure
    "podsecurity",    # Media: seguridad
    "affinity",       # Media: distribución nodos
    "hpa",            # Media: escalado
    "pdb",            # Media: resiliencia
    "networkpolicy",  # Media: aislamiento de red
    "docker-cleanup", # Baja: limpieza disco
]

# ─── Logger de remediaciones ──────────────────────────────────────────────────
class RemediationLogger:
    def __init__(self):
        self.entries  = []
        self.start    = datetime.datetime.utcnow()
        self.dry_run  = False

    def log(self, module, action, resource, namespace, status, cmd="", detail=""):
        self.entries.append({
            "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
            "module":    module,
            "action":    action,
            "resource":  resource,
            "namespace": namespace,
            "status":    status,
            "dry_run":   self.dry_run,
            "command":   cmd,
            "detail":    detail,
        })

    def save(self):
        ts   = self.start.strftime("%Y%m%d_%H%M%S")
        path = f"remediation_log_{ts}.json"
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"remediation_run": self.entries}, f, indent=2, ensure_ascii=False)
        return path

logger = RemediationLogger()

# ─── Helpers de output ────────────────────────────────────────────────────────

def banner():
    print(f"""
{C.BOLD}{C.CYAN}╔══════════════════════════════════════════════════════════╗
║   remediator_advanced — Remediador Modular Kubernetes    ║
║   Discover · Analyze · Confirm · Apply · Log             ║
╚══════════════════════════════════════════════════════════╝{C.RESET}
""")

def section(title):
    print(f"\n{C.BOLD}{C.MAGENTA}{'═'*60}{C.RESET}")
    print(f"{C.BOLD}{C.MAGENTA}  MÓDULO: {title}{C.RESET}")
    print(f"{C.BOLD}{C.MAGENTA}{'═'*60}{C.RESET}")

def ok(msg):     print(f"  {C.GREEN}✓{C.RESET} {msg}")
def warn(msg):   print(f"  {C.YELLOW}⚠{C.RESET}  {msg}")
def err(msg):    print(f"  {C.RED}✗{C.RESET} {msg}")
def info(msg):   print(f"  {C.BLUE}→{C.RESET} {msg}")
def skip(msg):   print(f"  {C.DIM}⊘ SKIP: {msg}{C.RESET}")
def dryrun(msg): print(f"  {C.CYAN}[DRY-RUN]{C.RESET} {msg}")

# ─── Utilidades kubectl ───────────────────────────────────────────────────────

def run_kubectl(args_list, timeout=30):
    cmd = ["kubectl"] + args_list
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            text=True,
        )
        stdout, stderr = proc.communicate(timeout=timeout)
        return stdout.strip(), stderr.strip(), proc.returncode
    except FileNotFoundError:
        return "", "kubectl no encontrado", -1
    except subprocess.TimeoutExpired:
        proc.kill(); proc.communicate()
        return "", "Timeout", -1
    except Exception as e:
        return "", str(e), -1

def run_shell(cmd, timeout=30):
    try:
        proc = subprocess.Popen(
            cmd, shell=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL, text=True,
        )
        stdout, stderr = proc.communicate(timeout=timeout)
        return stdout.strip(), stderr.strip(), proc.returncode
    except Exception as e:
        return "", str(e), -1

def cluster_reachable():
    _, _, code = run_kubectl(["cluster-info", "--request-timeout=5s"])
    return code == 0

def get_json(resource, namespace=None, extra_args=None):
    args = ["get", resource, "-o", "json"]
    if namespace:
        args += ["-n", namespace]
    else:
        args += ["--all-namespaces"]
    if extra_args:
        args += extra_args
    stdout, _, code = run_kubectl(args, timeout=30)
    if code != 0:
        return []
    return json.loads(stdout).get("items", [])

def get_namespaces(exclude_system=True):
    stdout, _, code = run_kubectl(["get", "namespaces", "-o", "json"])
    if code != 0:
        return []
    items = json.loads(stdout).get("items", [])
    result = [i["metadata"]["name"] for i in items]
    if exclude_system:
        result = [n for n in result if n not in SYSTEM_NAMESPACES]
    return result

# ─── Confirmación interactiva ─────────────────────────────────────────────────

def confirm(prompt, auto_approve=False):
    if auto_approve:
        print(f"  {C.CYAN}[AUTO-APPROVE]{C.RESET} {prompt}")
        return True
    sys.stdout.write(f"  {C.YELLOW}{prompt} [y/N]: {C.RESET}")
    sys.stdout.flush()
    choice = input().strip().lower()
    return choice in ("y", "yes")

def apply_or_dryrun(yaml_content, label, dry_run=False, auto_approve=False, module=""):
    """Aplica un manifiesto YAML inline, con backup y confirmación."""
    if dry_run:
        dryrun(f"kubectl apply (inline):\n{C.DIM}{yaml_content[:300]}...{C.RESET}")
        logger.log(module, "apply", label, "-", "DRY_RUN", "kubectl apply")
        return True

    if not confirm(f"¿Aplicar '{label}'?", auto_approve):
        skip(f"Omitido por operador: {label}")
        logger.log(module, "apply", label, "-", "SKIPPED")
        return False

    # Escribir a archivo temporal
    import tempfile
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False, encoding="utf-8") as tf:
        tf.write(yaml_content)
        tmp_path = tf.name

    try:
        stdout, stderr, code = run_kubectl(["apply", "--server-side", "-f", tmp_path], timeout=30)
        if code == 0:
            ok(f"Aplicado: {label}")
            logger.log(module, "apply", label, "-", "OK", f"kubectl apply -f {tmp_path}", stdout)
            return True
        else:
            err(f"Falló: {label} — {stderr}")
            logger.log(module, "apply", label, "-", "FAILED", "", stderr)
            return False
    finally:
        os.unlink(tmp_path)

def kubectl_patch(kind, name, namespace, patch_json, dry_run=False, auto_approve=False, module=""):
    """Aplica un patch estratégico a un recurso."""
    cmd_str = f"kubectl patch {kind} {name} -n {namespace} --type=strategic -p '{patch_json}'"

    if dry_run:
        dryrun(cmd_str)
        logger.log(module, "patch", f"{kind}/{name}", namespace, "DRY_RUN", cmd_str)
        return True

    if not confirm(f"¿Parchear {kind} '{name}' en '{namespace}'?", auto_approve):
        skip(f"Omitido: {kind}/{name}")
        logger.log(module, "patch", f"{kind}/{name}", namespace, "SKIPPED", cmd_str)
        return False

    stdout, stderr, code = run_kubectl(
        ["patch", kind, name, "-n", namespace,
         "--type=strategic", f"--patch={patch_json}"], timeout=20
    )
    if code == 0:
        ok(f"Parchado: {kind}/{name} en {namespace}")
        logger.log(module, "patch", f"{kind}/{name}", namespace, "OK", cmd_str, stdout)
        return True
    else:
        err(f"Patch fallido: {kind}/{name} — {stderr}")
        logger.log(module, "patch", f"{kind}/{name}", namespace, "FAILED", cmd_str, stderr)
        return False

def backup_resource(kind, name, namespace, backup_dir="./backups"):
    """Guarda el YAML actual de un recurso como backup."""
    os.makedirs(backup_dir, exist_ok=True)
    args = ["get", kind, name, "-o", "yaml"]
    if namespace:
        args += ["-n", namespace]
    stdout, _, code = run_kubectl(args, timeout=15)
    if code == 0 and stdout:
        ts_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d_%H%M%S")
        fname  = os.path.join(backup_dir, f"{namespace}_{kind}_{name}_{ts_str}.yaml")
        with open(fname, "w", encoding="utf-8") as f:
            f.write(stdout)
        return fname
    return None

# ─── MÓDULO: SCAN ─────────────────────────────────────────────────────────────

def cmd_scan(namespace_filter=None):
    """Vista ejecutiva del estado del clúster por namespace."""
    print(f"\n{C.BOLD}{C.CYAN}  ESCANEO DEL CLÚSTER{C.RESET}\n")

    namespaces = [namespace_filter] if namespace_filter else get_namespaces()
    if not namespaces:
        warn("No se encontraron namespaces de negocio")
        return

    deps_all  = get_json("deployments")
    hpas_all  = get_json("hpa")
    pdbs_all  = get_json("pdb")
    nets_all  = get_json("networkpolicies")

    hpa_keys  = {(h["metadata"]["namespace"], h["spec"]["scaleTargetRef"]["name"]) for h in hpas_all}
    pdb_ns    = {p["metadata"]["namespace"] for p in pdbs_all}
    net_ns    = {n["metadata"]["namespace"] for n in nets_all}

    # Cabecera
    print(f"  {C.BOLD}{'NAMESPACE':<28} {'DEPS':>4} {'HPA':>5} {'PDB':>5} {'NETPOL':>7} {'ISSUES':>7}{C.RESET}")
    print(f"  {'─'*62}")

    total_issues = 0
    for ns in sorted(namespaces):
        if ns in SYSTEM_NAMESPACES:
            continue
        deps_ns = [d for d in deps_all if d["metadata"]["namespace"] == ns]
        if not deps_ns:
            continue

        hpa_count   = sum(1 for d in deps_ns if (ns, d["metadata"]["name"]) in hpa_keys)
        has_pdb     = ns in pdb_ns
        has_netpol  = ns in net_ns

        issues = 0
        for dep in deps_ns:
            from yaml_builder_utils import analyze_dep_issues
            issues += analyze_dep_issues(dep, hpa_keys, pdb_ns)

        total_issues += issues

        hpa_str   = f"{C.GREEN}{hpa_count}/{len(deps_ns)}{C.RESET}" if hpa_count == len(deps_ns) else f"{C.RED}{hpa_count}/{len(deps_ns)}{C.RESET}"
        pdb_str   = f"{C.GREEN}✓{C.RESET}" if has_pdb else f"{C.RED}✗{C.RESET}"
        net_str   = f"{C.GREEN}✓{C.RESET}" if has_netpol else f"{C.RED}✗{C.RESET}"
        iss_str   = f"{C.RED}{issues}{C.RESET}" if issues > 0 else f"{C.GREEN}0{C.RESET}"

        print(f"  {ns:<28} {len(deps_ns):>4}  {hpa_str}   {pdb_str}   {net_str}    {iss_str}")

    print(f"  {'─'*62}")
    print(f"  {C.BOLD}Total issues encontrados: {C.RED}{total_issues}{C.RESET}")
    print(f"\n  {C.DIM}Tip: usa '--module all --dry-run' para ver qué se remediaría.{C.RESET}\n")

def _analyze_dep_issues(dep, hpa_keys, pdb_ns):
    """Cuenta issues en un Deployment (sin importar yaml_builder)."""
    issues = 0
    name      = dep["metadata"]["name"]
    namespace = dep["metadata"]["namespace"]
    spec      = dep.get("spec", {})
    replicas  = spec.get("replicas", 1)
    containers = spec.get("template", {}).get("spec", {}).get("containers", [])
    strategy  = spec.get("strategy", {}).get("type", "RollingUpdate")
    affinity  = spec.get("template", {}).get("spec", {}).get("affinity", {})

    if strategy == "Recreate": issues += 1
    if replicas < 2: issues += 1
    if not affinity.get("podAntiAffinity"): issues += 1
    if (namespace, name) not in hpa_keys: issues += 1
    if namespace not in pdb_ns: issues += 1

    for c in containers:
        r = c.get("resources", {})
        if not r.get("requests", {}).get("cpu"): issues += 1
        if not r.get("limits", {}).get("cpu"): issues += 1
        if not r.get("limits", {}).get("ephemeral-storage"): issues += 1
        if not c.get("livenessProbe"): issues += 1
        if not c.get("readinessProbe"): issues += 1
        sc = c.get("securityContext", {})
        if not sc.get("runAsNonRoot"): issues += 1
    return issues


def cmd_scan_inline(namespace_filter=None):
    """Vista ejecutiva del estado del clúster por namespace (sin import externo)."""
    print(f"\n{C.BOLD}{C.CYAN}  ESCANEO DEL CLÚSTER — SENIAT Kubernetes{C.RESET}\n")

    namespaces = [namespace_filter] if namespace_filter else get_namespaces()
    if not namespaces:
        warn("No se encontraron namespaces de negocio")
        return

    deps_all = get_json("deployments")
    hpas_all = get_json("hpa")
    pdbs_all = get_json("pdb")
    nets_all = get_json("networkpolicies")

    hpa_keys = {(h["metadata"]["namespace"], h["spec"]["scaleTargetRef"]["name"]) for h in hpas_all}
    pdb_ns   = {p["metadata"]["namespace"] for p in pdbs_all}
    net_ns   = {n["metadata"]["namespace"] for n in nets_all}

    # Obtener nodos
    stdout, _, _ = run_kubectl(["get", "nodes", "--no-headers"])
    node_count = len([l for l in stdout.splitlines() if l.strip()])

    print(f"  {C.BOLD}Nodos en el clúster: {node_count}{C.RESET}\n")
    print(f"  {C.BOLD}{'NAMESPACE':<28} {'DEPS':>4} {'HPA':>7} {'PDB':>5} {'NETPOL':>7} {'ISSUES':>8}{C.RESET}")
    print(f"  {'─'*65}")

    total_issues = 0
    for ns in sorted(namespaces):
        if ns in SYSTEM_NAMESPACES:
            continue
        deps_ns = [d for d in deps_all if d["metadata"]["namespace"] == ns]
        if not deps_ns:
            continue

        hpa_count  = sum(1 for d in deps_ns if (ns, d["metadata"]["name"]) in hpa_keys)
        has_pdb    = ns in pdb_ns
        has_netpol = ns in net_ns

        issues = sum(_analyze_dep_issues(d, hpa_keys, pdb_ns) for d in deps_ns)
        total_issues += issues

        hpa_str  = f"{C.GREEN}{hpa_count}/{len(deps_ns)}{C.RESET}" if hpa_count == len(deps_ns) else f"{C.RED}{hpa_count}/{len(deps_ns)}{C.RESET}"
        pdb_str  = f"{C.GREEN}SI{C.RESET}" if has_pdb else f"{C.RED}NO{C.RESET}"
        net_str  = f"{C.GREEN}SI{C.RESET}" if has_netpol else f"{C.RED}NO{C.RESET}"
        iss_color = C.RED if issues > 0 else C.GREEN
        icon     = "🔴" if issues > 10 else ("⚠️ " if issues > 0 else "✅")

        print(f"  {ns:<28} {len(deps_ns):>4}  {hpa_str:<15} {pdb_str:<8} {net_str:<10} {iss_color}{icon} {issues}{C.RESET}")

    print(f"  {'─'*65}")
    print(f"  {C.BOLD}Total issues detectados en el clúster: {C.RED}{total_issues}{C.RESET}")
    print(f"\n  {C.DIM}Tip: usa '--module <nombre> --dry-run' para simular la remediación.{C.RESET}\n")

# ─── MÓDULO: HPA ──────────────────────────────────────────────────────────────

def module_hpa(namespace_filter=None, dry_run=False, auto_approve=False):
    section("HPA — HorizontalPodAutoscaler")
    deps = get_json("deployments", namespace_filter)
    hpas = get_json("hpa", namespace_filter)
    hpa_keys = {(h["metadata"]["namespace"], h["spec"]["scaleTargetRef"]["name"]) for h in hpas}

    found = 0
    for dep in deps:
        name = dep["metadata"]["name"]
        ns   = dep["metadata"]["namespace"]
        if ns in SYSTEM_NAMESPACES:
            continue
        if (ns, name) in hpa_keys:
            continue

        # Verificar que tiene requests.cpu (prerequisito de HPA)
        containers = dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        has_cpu_req = any(
            c.get("resources", {}).get("requests", {}).get("cpu")
            for c in containers
        )
        if not has_cpu_req:
            warn(f"Omitido {name} ({ns}): sin requests.cpu — aplica módulo 'resources' primero")
            continue

        found += 1
        info(f"Sin HPA: {C.BOLD}{name}{C.RESET} ({ns})")

        yaml_content = f"""\
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {name}
  namespace: {ns}
  labels:
    app.kubernetes.io/name: {name}
    app.kubernetes.io/managed-by: remediator-advanced
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {name}
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 80
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 85
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
    scaleUp:
      stabilizationWindowSeconds: 60
"""
        apply_or_dryrun(yaml_content, f"HPA/{name} ({ns})", dry_run, auto_approve, "hpa")

    if found == 0:
        ok("Todos los Deployments ya tienen HPA configurado")

# ─── MÓDULO: PDB ──────────────────────────────────────────────────────────────

def module_pdb(namespace_filter=None, dry_run=False, auto_approve=False):
    section("PDB — PodDisruptionBudget")
    deps = get_json("deployments", namespace_filter)
    pdbs = get_json("pdb", namespace_filter)
    pdb_ns_names = {(p["metadata"]["namespace"], p["spec"].get("selector", {}).get("matchLabels", {}).get("app", "")) for p in pdbs}

    found = 0
    for dep in deps:
        name     = dep["metadata"]["name"]
        ns       = dep["metadata"]["namespace"]
        replicas = dep.get("spec", {}).get("replicas", 1)
        if ns in SYSTEM_NAMESPACES:
            continue
        if replicas < 2:
            info(f"Omitido {name} ({ns}): solo {replicas} réplica(s). Aplica 'replicas' primero.")
            continue
        if (ns, name) in pdb_ns_names:
            continue

        found += 1
        info(f"Sin PDB: {C.BOLD}{name}{C.RESET} ({ns}, réplicas={replicas})")

        yaml_content = f"""\
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {name}-pdb
  namespace: {ns}
  labels:
    app.kubernetes.io/name: {name}
    app.kubernetes.io/managed-by: remediator-advanced
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: {name}
"""
        apply_or_dryrun(yaml_content, f"PDB/{name} ({ns})", dry_run, auto_approve, "pdb")

    if found == 0:
        ok("Todos los Deployments con múltiples réplicas ya tienen PDB")

# ─── MÓDULO: NETWORKPOLICY ────────────────────────────────────────────────────

def module_networkpolicy(namespace_filter=None, dry_run=False, auto_approve=False):
    section("NETWORKPOLICY — Aislamiento de Red")
    namespaces = [namespace_filter] if namespace_filter else get_namespaces()
    existing_net_ns = {n["metadata"]["namespace"] for n in get_json("networkpolicies", namespace_filter)}

    found = 0
    for ns in namespaces:
        if ns in SYSTEM_NAMESPACES:
            continue
        if ns in existing_net_ns:
            ok(f"NetworkPolicy ya existe en: {ns}")
            continue
        found += 1
        info(f"Sin NetworkPolicy: {C.BOLD}{ns}{C.RESET}")

        yaml_content = f"""\
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: {ns}
  labels:
    app.kubernetes.io/managed-by: remediator-advanced
spec:
  podSelector: {{}}
  policyTypes:
    - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ingress-nginx
  namespace: {ns}
  labels:
    app.kubernetes.io/managed-by: remediator-advanced
spec:
  podSelector: {{}}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-namespace
  namespace: {ns}
  labels:
    app.kubernetes.io/managed-by: remediator-advanced
spec:
  podSelector: {{}}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {{}}
"""
        apply_or_dryrun(yaml_content, f"NetworkPolicy/{ns}", dry_run, auto_approve, "networkpolicy")

    if found == 0:
        ok("Todos los namespaces ya tienen NetworkPolicy")

# ─── MÓDULO: RESOURCES ────────────────────────────────────────────────────────

def module_resources(namespace_filter=None, dry_run=False, auto_approve=False):
    section("RESOURCES — requests y limits CPU/RAM")
    deps = get_json("deployments", namespace_filter)

    found = 0
    for dep in deps:
        name = dep["metadata"]["name"]
        ns   = dep["metadata"]["namespace"]
        if ns in SYSTEM_NAMESPACES:
            continue

        containers = dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        needs_patch = False
        for c in containers:
            r = c.get("resources", {})
            if not r.get("requests", {}).get("cpu") or not r.get("limits", {}).get("cpu"):
                needs_patch = True
                break

        if not needs_patch:
            continue

        found += 1
        info(f"Sin resources: {C.BOLD}{name}{C.RESET} ({ns})")

        # Construir patch de containers
        containers_patch = []
        for c in containers:
            cname = c.get("name")
            r     = c.get("resources", {})
            req   = r.get("requests", {})
            lim   = r.get("limits", {})
            containers_patch.append({
                "name": cname,
                "resources": {
                    "requests": {
                        "cpu":               req.get("cpu",    "100m"),
                        "memory":            req.get("memory", "128Mi"),
                        "ephemeral-storage": "100Mi",
                    },
                    "limits": {
                        "cpu":               lim.get("cpu",    "500m"),
                        "memory":            lim.get("memory", "512Mi"),
                        "ephemeral-storage": "500Mi",
                    },
                }
            })

        patch = json.dumps({
            "spec": {
                "template": {
                    "spec": {
                        "containers": containers_patch
                    }
                }
            }
        })

        bak = backup_resource("deployment", name, ns)
        if bak:
            info(f"Backup: {bak}")

        kubectl_patch("deployment", name, ns, patch, dry_run, auto_approve, "resources")

    if found == 0:
        ok("Todos los Deployments tienen resources definidos")

# ─── MÓDULO: REPLICAS ─────────────────────────────────────────────────────────

def module_replicas(namespace_filter=None, dry_run=False, auto_approve=False):
    section("REPLICAS — Mínimo 2 réplicas (eliminar SPOF)")
    deps = get_json("deployments", namespace_filter)

    found = 0
    for dep in deps:
        name     = dep["metadata"]["name"]
        ns       = dep["metadata"]["namespace"]
        replicas = dep.get("spec", {}).get("replicas", 1)
        if ns in SYSTEM_NAMESPACES:
            continue
        if replicas >= 2:
            continue

        found += 1
        info(f"Réplicas={replicas}: {C.BOLD}{name}{C.RESET} ({ns})")
        patch = json.dumps({"spec": {"replicas": 2}})
        kubectl_patch("deployment", name, ns, patch, dry_run, auto_approve, "replicas")

    if found == 0:
        ok("Todos los Deployments tienen 2 o más réplicas")

# ─── MÓDULO: STRATEGY ─────────────────────────────────────────────────────────

def module_strategy(namespace_filter=None, dry_run=False, auto_approve=False):
    section("STRATEGY — Migrar Recreate → RollingUpdate (zero-downtime)")
    deps = get_json("deployments", namespace_filter)

    found = 0
    for dep in deps:
        name     = dep["metadata"]["name"]
        ns       = dep["metadata"]["namespace"]
        strategy = dep.get("spec", {}).get("strategy", {}).get("type", "RollingUpdate")
        if ns in SYSTEM_NAMESPACES:
            continue
        if strategy != "Recreate":
            continue

        found += 1
        info(f"Estrategia Recreate: {C.BOLD}{name}{C.RESET} ({ns})")
        patch = json.dumps({
            "spec": {
                "strategy": {
                    "type": "RollingUpdate",
                    "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}
                }
            }
        })
        bak = backup_resource("deployment", name, ns)
        if bak:
            info(f"Backup: {bak}")
        kubectl_patch("deployment", name, ns, patch, dry_run, auto_approve, "strategy")

    if found == 0:
        ok("Ningún Deployment usa estrategia Recreate")

# ─── MÓDULO: RBAC ─────────────────────────────────────────────────────────────

def module_rbac(namespace_filter=None, dry_run=False, auto_approve=False):
    section("RBAC — Revisar cluster-admin en ServiceAccounts")

    stdout, _, code = run_kubectl([
        "get", "clusterrolebindings", "-o", "json"
    ], timeout=20)

    if code != 0:
        err("No se pudo listar ClusterRoleBindings")
        return

    crbs = json.loads(stdout).get("items", [])
    found = 0

    for crb in crbs:
        role_ref = crb.get("roleRef", {})
        if role_ref.get("name") != "cluster-admin":
            continue

        subjects = crb.get("subjects", [])
        for subj in subjects:
            if subj.get("kind") != "ServiceAccount":
                continue
            sa_ns   = subj.get("namespace", "")
            sa_name = subj.get("name", "")
            if sa_ns in SYSTEM_NAMESPACES:
                skip(f"ServiceAccount de sistema: {sa_name} ({sa_ns})")
                continue

            found += 1
            crb_name = crb["metadata"]["name"]
            warn(f"cluster-admin: {C.RED}{sa_name}{C.RESET} ({sa_ns}) via ClusterRoleBinding '{crb_name}'")
            print(f"  {C.DIM}  Acción recomendada: revocar cluster-admin y crear ClusterRole de mínimo privilegio{C.RESET}")

            # Backup del CRB antes de cualquier acción
            bak = backup_resource("clusterrolebinding", crb_name, "")
            if bak:
                info(f"Backup del CRB: {bak}")

            if dry_run:
                dryrun(f"kubectl delete clusterrolebinding {crb_name}")
                dryrun(f"kubectl create rolebinding {sa_name}-read -n {sa_ns} --clusterrole=view --serviceaccount={sa_ns}:{sa_name}")
                logger.log("rbac", "review-cluster-admin", sa_name, sa_ns, "DRY_RUN")
            else:
                warn(f"¿Revocar cluster-admin de {sa_name} ({sa_ns})? Esta acción puede interrumpir servicios.")
                if confirm(f"¿Eliminar ClusterRoleBinding '{crb_name}'?", auto_approve):
                    _, stderr, code2 = run_kubectl(["delete", "clusterrolebinding", crb_name], timeout=15)
                    if code2 == 0:
                        ok(f"ClusterRoleBinding '{crb_name}' eliminado")
                        logger.log("rbac", "delete-crb", crb_name, sa_ns, "OK")
                    else:
                        err(f"Error eliminando CRB: {stderr}")
                        logger.log("rbac", "delete-crb", crb_name, sa_ns, "FAILED", "", stderr)

    if found == 0:
        ok("No se encontraron ServiceAccounts con cluster-admin fuera del sistema")

# ─── MÓDULO: DOCKER-CLEANUP ───────────────────────────────────────────────────

def module_docker_cleanup(dry_run=False, auto_approve=False):
    section("DOCKER-CLEANUP — Imágenes huérfanas (dangling)")

    stdout, _, code = run_shell("docker images -f dangling=true --format '{{.ID}} {{.Size}}'", timeout=15)
    if code != 0:
        warn("Docker no disponible o requiere permisos adicionales")
        return

    lines = [l for l in stdout.splitlines() if l.strip()]
    if not lines:
        ok("No hay imágenes huérfanas (dangling)")
        return

    print(f"  {C.YELLOW}Imágenes huérfanas encontradas: {len(lines)}{C.RESET}")
    for l in lines[:10]:
        print(f"    {C.DIM}{l}{C.RESET}")

    if dry_run:
        dryrun("docker image prune -f")
        logger.log("docker-cleanup", "prune", "dangling-images", "host", "DRY_RUN", "docker image prune -f")
        return

    if confirm("¿Eliminar todas las imágenes huérfanas con 'docker image prune -f'?", auto_approve):
        stdout2, stderr2, code2 = run_shell("docker image prune -f", timeout=60)
        if code2 == 0:
            ok(f"Limpieza completada:\n{C.DIM}    {stdout2}{C.RESET}")
            logger.log("docker-cleanup", "prune", "dangling-images", "host", "OK", "docker image prune -f", stdout2)
        else:
            err(f"Error en limpieza: {stderr2}")
            logger.log("docker-cleanup", "prune", "dangling-images", "host", "FAILED", "", stderr2)

# ─── MÓDULO: CERTIFICATES ─────────────────────────────────────────────────────

def module_certificates(dry_run=False, auto_approve=False):
    section("CERTIFICATES — Renovación de certificados")

    stdout, _, code = run_shell("kubeadm certs check-expiration 2>/dev/null", timeout=15)

    if code != 0:
        warn("kubeadm no disponible o requiere ejecución en el Control Plane con sudo")
        print(f"""
  {C.YELLOW}Guía manual para renovar certificados:{C.RESET}

  1. Verificar certificados actuales:
     {C.CYAN}sudo kubeadm certs check-expiration{C.RESET}

  2. Renovar TODOS los certificados del plano de control:
     {C.CYAN}sudo kubeadm certs renew all{C.RESET}

  3. Renovar kubelet.crt (certificado expirado -429 días):
     {C.CYAN}sudo kubeadm certs renew kubelet{C.RESET}
     o si usas kubelet-client:
     {C.CYAN}sudo kubeadm certs renew kubelet-client{C.RESET}

  4. Reiniciar los componentes del Control Plane:
     {C.CYAN}sudo systemctl restart kubelet{C.RESET}

  5. Verificar que los certificados se renovaron:
     {C.CYAN}sudo kubeadm certs check-expiration{C.RESET}

  {C.RED}⚠️  IMPORTANTE: Ejecuta estos comandos en CADA Control Plane.{C.RESET}
  {C.RED}    kubelet.crt lleva -429 días expirado — debe renovarse urgentemente.{C.RESET}
""")
        return

    print(f"\n{C.DIM}{stdout}{C.RESET}\n")

    expiring = []
    for line in stdout.splitlines():
        if "MISSING" in line or "Invalid" in line or "-" in line.split()[-1] if line.strip() else False:
            expiring.append(line.strip())

    if expiring:
        warn("Certificados expirados o inválidos detectados:")
        for e in expiring:
            print(f"    {C.RED}{e}{C.RESET}")
    else:
        ok("Todos los certificados están vigentes")

    if dry_run:
        dryrun("sudo kubeadm certs renew all")
        dryrun("sudo systemctl restart kubelet")
        return

    if expiring and confirm("¿Ejecutar 'kubeadm certs renew all'? (Requiere sudo en el Control Plane)", auto_approve):
        stdout2, stderr2, code2 = run_shell("sudo kubeadm certs renew all", timeout=120)
        if code2 == 0:
            ok(f"Certificados renovados:\n{C.DIM}{stdout2}{C.RESET}")
            logger.log("certificates", "renew-all", "certs", "control-plane", "OK", "kubeadm certs renew all")
            info("Reiniciando kubelet...")
            run_shell("sudo systemctl restart kubelet", timeout=30)
            ok("kubelet reiniciado")
        else:
            err(f"Error renovando certs: {stderr2}")
            logger.log("certificates", "renew-all", "certs", "control-plane", "FAILED", "", stderr2)

# ─── MÓDULO: PODSECURITY ──────────────────────────────────────────────────────

def module_podsecurity(namespace_filter=None, dry_run=False, auto_approve=False):
    section("PODSECURITY — securityContext en contenedores")
    deps = get_json("deployments", namespace_filter)

    found = 0
    for dep in deps:
        name = dep["metadata"]["name"]
        ns   = dep["metadata"]["namespace"]
        if ns in SYSTEM_NAMESPACES:
            continue

        containers = dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        needs_patch = False
        for c in containers:
            sc = c.get("securityContext", {})
            if not sc.get("runAsNonRoot") or sc.get("allowPrivilegeEscalation") is not False:
                needs_patch = True
                break

        if not needs_patch:
            continue

        # Verificar si algún contenedor está en whitelist de privileged
        containers_patch = []
        for c in containers:
            cname = c.get("name", "")
            sc    = c.get("securityContext", {})

            if cname in PRIVILEGED_WHITELIST or sc.get("privileged"):
                skip(f"Contenedor privilegiado del sistema: {cname} en {name} — NO TOCAR (requerido por CNI/sistema)")
                continue

            containers_patch.append({
                "name": cname,
                "securityContext": {
                    "runAsNonRoot":              True,
                    "allowPrivilegeEscalation":  False,
                    "readOnlyRootFilesystem":    False,
                    "capabilities": {"drop": ["ALL"]},
                }
            })

        if not containers_patch:
            continue

        found += 1
        info(f"Sin securityContext correcto: {C.BOLD}{name}{C.RESET} ({ns})")

        patch = json.dumps({
            "spec": {
                "template": {
                    "spec": {
                        "containers": containers_patch
                    }
                }
            }
        })

        bak = backup_resource("deployment", name, ns)
        if bak:
            info(f"Backup: {bak}")
        kubectl_patch("deployment", name, ns, patch, dry_run, auto_approve, "podsecurity")

    if found == 0:
        ok("Todos los Deployments tienen securityContext correcto")

# ─── MÓDULO: AFFINITY ─────────────────────────────────────────────────────────

def module_affinity(namespace_filter=None, dry_run=False, auto_approve=False):
    section("AFFINITY — podAntiAffinity para distribución entre nodos")
    deps = get_json("deployments", namespace_filter)

    found = 0
    for dep in deps:
        name     = dep["metadata"]["name"]
        ns       = dep["metadata"]["namespace"]
        replicas = dep.get("spec", {}).get("replicas", 1)
        if ns in SYSTEM_NAMESPACES:
            continue
        if replicas < 2:
            continue  # Solo importa para multi-réplica

        pod_spec = dep.get("spec", {}).get("template", {}).get("spec", {})
        if pod_spec.get("affinity", {}).get("podAntiAffinity"):
            continue

        found += 1
        info(f"Sin podAntiAffinity: {C.BOLD}{name}{C.RESET} ({ns}, réplicas={replicas})")

        patch = json.dumps({
            "spec": {
                "template": {
                    "spec": {
                        "affinity": {
                            "podAntiAffinity": {
                                "preferredDuringSchedulingIgnoredDuringExecution": [
                                    {
                                        "weight": 100,
                                        "podAffinityTerm": {
                                            "labelSelector": {
                                                "matchLabels": {"app": name}
                                            },
                                            "topologyKey": "kubernetes.io/hostname"
                                        }
                                    }
                                ]
                            }
                        }
                    }
                }
            }
        })
        kubectl_patch("deployment", name, ns, patch, dry_run, auto_approve, "affinity")

    if found == 0:
        ok("Todos los Deployments multi-réplica tienen podAntiAffinity")

# ─── MÓDULO: EPHEMERAL ────────────────────────────────────────────────────────

def module_ephemeral(namespace_filter=None, dry_run=False, auto_approve=False):
    section("EPHEMERAL — Límites de ephemeral-storage")
    deps = get_json("deployments", namespace_filter)

    found = 0
    for dep in deps:
        name = dep["metadata"]["name"]
        ns   = dep["metadata"]["namespace"]
        if ns in SYSTEM_NAMESPACES:
            continue

        containers = dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        needs_patch = any(
            not c.get("resources", {}).get("limits", {}).get("ephemeral-storage")
            for c in containers
        )
        if not needs_patch:
            continue

        found += 1
        info(f"Sin ephemeral-storage: {C.BOLD}{name}{C.RESET} ({ns})")

        containers_patch = []
        for c in containers:
            cname = c.get("name")
            r     = c.get("resources", {})
            req   = r.get("requests", {})
            lim   = r.get("limits", {})
            containers_patch.append({
                "name": cname,
                "resources": {
                    "requests": {
                        **req,
                        "ephemeral-storage": req.get("ephemeral-storage", "100Mi"),
                    },
                    "limits": {
                        **lim,
                        "ephemeral-storage": lim.get("ephemeral-storage", "500Mi"),
                    },
                }
            })

        patch = json.dumps({
            "spec": {"template": {"spec": {"containers": containers_patch}}}
        })
        kubectl_patch("deployment", name, ns, patch, dry_run, auto_approve, "ephemeral")

    if found == 0:
        ok("Todos los Deployments tienen límites de ephemeral-storage")

# ─── PUNTO DE ENTRADA ─────────────────────────────────────────────────────────

MODULES = {
    "hpa":            module_hpa,
    "pdb":            module_pdb,
    "networkpolicy":  module_networkpolicy,
    "resources":      module_resources,
    "replicas":       module_replicas,
    "strategy":       module_strategy,
    "rbac":           module_rbac,
    "docker-cleanup": module_docker_cleanup,
    "certificates":   module_certificates,
    "podsecurity":    module_podsecurity,
    "affinity":       module_affinity,
    "ephemeral":      module_ephemeral,
}

MODULE_DESCRIPTIONS = {
    "hpa":            "Crear HPAs para Deployments sin escalado automático",
    "pdb":            "Crear PDBs para Deployments sin protección a disrupciones",
    "networkpolicy":  "NetworkPolicy deny-all + allow por namespace",
    "resources":      "Parchar resources requests/limits en Deployments",
    "replicas":       "Escalar a mínimo 2 los Deployments con réplica única (SPOF)",
    "strategy":       "Migrar estrategia Recreate → RollingUpdate (zero-downtime)",
    "rbac":           "Revisar y remediar ServiceAccounts con cluster-admin",
    "docker-cleanup": "Limpiar imágenes Docker huérfanas (dangling)",
    "certificates":   "Guía interactiva para renovar certificados expirados",
    "podsecurity":    "Parchar securityContext (runAsNonRoot, capabilities)",
    "affinity":       "Agregar podAntiAffinity soft para distribución entre nodos",
    "ephemeral":      "Agregar límites de ephemeral-storage a contenedores",
}

def needs_namespace(module_name):
    return module_name not in ("docker-cleanup", "certificates", "rbac")

def main():
    banner()

    parser = argparse.ArgumentParser(
        description="remediator_advanced — Remediador Modular Kubernetes Cluster-Aware"
    )
    parser.add_argument("--scan",          action="store_true", help="Escanear el clúster y mostrar estado por namespace")
    parser.add_argument("--list-modules",  action="store_true", help="Listar módulos disponibles")
    parser.add_argument("--module",   "-m", help="Módulo a ejecutar (o 'all' para todos)")
    parser.add_argument("--namespace", "-n", help="Namespace a remediar (omitir = todos)")
    parser.add_argument("--dry-run",        action="store_true", help="Simular sin aplicar cambios")
    parser.add_argument("--auto-approve",   action="store_true", help="Sin prompts interactivos")
    parser.add_argument("--report",         help="Ruta al JSON de auditoría (opcional, para contexto extra)")
    args = parser.parse_args()

    logger.dry_run = args.dry_run

    if args.dry_run:
        print(f"  {C.YELLOW}⚠  MODO DRY-RUN ACTIVO — No se aplicará ningún cambio{C.RESET}\n")

    if args.list_modules:
        print(f"\n  {C.BOLD}Módulos disponibles:{C.RESET}\n")
        for k, desc in MODULE_DESCRIPTIONS.items():
            print(f"    {C.CYAN}{k:<18}{C.RESET} {desc}")
        print(f"\n  Uso: --module <nombre> [--dry-run] [--namespace NS]\n")
        return

    if not cluster_reachable():
        err("No se puede conectar al clúster. Verifica tu kubeconfig.")
        sys.exit(1)

    if args.scan:
        cmd_scan_inline(args.namespace)
        return

    if not args.module:
        err("Especifica --scan, --list-modules o --module <nombre>")
        sys.exit(1)

    ns = args.namespace

    if args.module == "all":
        print(f"\n  {C.BOLD}Ejecutando todos los módulos en orden de prioridad...{C.RESET}\n")
        for mod_name in MODULE_PRIORITY_ORDER:
            fn = MODULES[mod_name]
            try:
                if mod_name in ("docker-cleanup", "certificates"):
                    fn(dry_run=args.dry_run, auto_approve=args.auto_approve)
                elif mod_name == "rbac":
                    fn(namespace_filter=ns, dry_run=args.dry_run, auto_approve=args.auto_approve)
                else:
                    fn(namespace_filter=ns, dry_run=args.dry_run, auto_approve=args.auto_approve)
            except Exception as e:
                err(f"Error en módulo '{mod_name}': {e}")
    else:
        mod_name = args.module
        if mod_name not in MODULES:
            err(f"Módulo '{mod_name}' no reconocido. Usa --list-modules para ver los disponibles.")
            sys.exit(1)

        fn = MODULES[mod_name]
        if mod_name in ("docker-cleanup", "certificates"):
            fn(dry_run=args.dry_run, auto_approve=args.auto_approve)
        else:
            fn(namespace_filter=ns, dry_run=args.dry_run, auto_approve=args.auto_approve)

    # Guardar log
    if args.module:
        log_path = logger.save()
        print(f"\n  {C.DIM}Log de remediación guardado en: {log_path}{C.RESET}\n")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
auto_deploy.py — Desplegador Automático Kubernetes con Rollback
==============================================================
Flujo:
  [1] Validación YAML (kubectl --dry-run=client)
  [2] Diff contra estado actual (kubectl diff)
  [3] Backup del recurso actual (kubectl get -o yaml)
  [4] Apply (kubectl apply --server-side)
  [5] Health check (kubectl rollout status)
  [6] Si falla → rollback automático (kubectl rollout undo)
  [7] Log de todas las acciones

Uso:
  python3 auto_deploy.py --file manifest.yaml [--dry-run] [--auto-rollback] [--timeout 300]
  python3 auto_deploy.py --from-dir ./manifests/ --namespace servicios-declaracion
  python3 auto_deploy.py --rollback --name consulta --namespace servicios-declaracion
  python3 auto_deploy.py --status --namespace servicios-declaracion
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

SYSTEM_NAMESPACES = {
    "kube-system", "kube-public", "kube-node-lease",
    "calico-system", "calico-apiserver", "tigera-operator",
    "metallb-system", "lens-metrics",
}

# ─── Logger de acciones ───────────────────────────────────────────────────────
class DeployLogger:
    def __init__(self):
        self.entries = []
        self.start   = datetime.datetime.utcnow()

    def log(self, action, resource, namespace, status, detail=""):
        entry = {
            "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
            "action":    action,
            "resource":  resource,
            "namespace": namespace,
            "status":    status,
            "detail":    detail,
        }
        self.entries.append(entry)

    def save(self, path=None):
        if path is None:
            ts   = self.start.strftime("%Y%m%d_%H%M%S")
            path = f"deploy_log_{ts}.json"
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"deploy_run": self.entries}, f, indent=2, ensure_ascii=False)
        return path

logger = DeployLogger()

# ─── Utilidades ───────────────────────────────────────────────────────────────

def banner():
    print(f"""
{C.BOLD}{C.CYAN}╔══════════════════════════════════════════════════════════╗
║      auto_deploy — Desplegador Kubernetes con Rollback   ║
║      Validate · Backup · Apply · Health-Check · Rollback ║
╚══════════════════════════════════════════════════════════╝{C.RESET}
""")

def ts():
    return datetime.datetime.utcnow().strftime("%H:%M:%S")

def ok(msg):   print(f"  {C.GREEN}[{ts()}] ✓{C.RESET} {msg}")
def warn(msg): print(f"  {C.YELLOW}[{ts()}] ⚠{C.RESET}  {msg}")
def err(msg):  print(f"  {C.RED}[{ts()}] ✗{C.RESET} {msg}")
def info(msg): print(f"  {C.BLUE}[{ts()}] →{C.RESET} {msg}")
def step(n, title):
    print(f"\n  {C.BOLD}{C.CYAN}[PASO {n}] {title}{C.RESET}")

def run_kubectl(args_list, timeout=30, capture=True):
    cmd = ["kubectl"] + args_list
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            stdin=subprocess.DEVNULL,
            text=True,
        )
        stdout, stderr = proc.communicate(timeout=timeout)
        return (stdout or "").strip(), (stderr or "").strip(), proc.returncode
    except FileNotFoundError:
        return "", "kubectl no encontrado", -1
    except subprocess.TimeoutExpired:
        proc.kill(); proc.communicate()
        return "", "Timeout", -1
    except Exception as e:
        return "", str(e), -1

def cluster_reachable():
    _, _, code = run_kubectl(["cluster-info", "--request-timeout=5s"])
    return code == 0

def list_yaml_files(directory):
    return sorted([
        os.path.join(directory, f)
        for f in os.listdir(directory)
        if f.endswith(".yaml") or f.endswith(".yml")
    ])

def extract_resources_from_yaml(filepath):
    """Extrae (kind, name, namespace) de un archivo YAML (sin parsear YAML complejo)."""
    resources = []
    kind = name = namespace = None
    with open(filepath, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("kind:"):
                kind = line.split(":", 1)[1].strip()
            elif line.startswith("  name:"):
                name = line.split(":", 1)[1].strip()
            elif line.startswith("  namespace:"):
                namespace = line.split(":", 1)[1].strip()
            elif line == "---":
                if kind and name:
                    resources.append((kind, name, namespace or "default"))
                kind = name = namespace = None
    if kind and name:
        resources.append((kind, name, namespace or "default"))
    return resources

# ─── PASO 1: Validación ───────────────────────────────────────────────────────

def validate_yaml(filepath):
    step(1, "Validación YAML (dry-run=client)")
    stdout, stderr, code = run_kubectl(
        ["apply", "--dry-run=client", "-f", filepath], timeout=30
    )
    if code == 0:
        ok(f"Validación exitosa: {os.path.basename(filepath)}")
        return True
    else:
        err(f"Validación fallida: {stderr}")
        return False

# ─── PASO 2: Diff ─────────────────────────────────────────────────────────────

def show_diff(filepath):
    step(2, "Diff contra el clúster actual")
    stdout, stderr, code = run_kubectl(["diff", "-f", filepath], timeout=30)
    if code == 0:
        ok("Sin cambios detectados (estado ya sincronizado)")
    elif code == 1:
        print(f"\n{C.DIM}{stdout}{C.RESET}\n")
    else:
        warn(f"kubectl diff retornó código {code}: {stderr}")
    return code

# ─── PASO 3: Backup ───────────────────────────────────────────────────────────

def backup_resources(filepath, backup_dir):
    step(3, f"Backup del estado actual → {backup_dir}")
    os.makedirs(backup_dir, exist_ok=True)

    resources = extract_resources_from_yaml(filepath)
    backed_up = []

    for kind, name, namespace in resources:
        if kind.lower() in ("namespace", "clusterrole", "clusterrolebinding"):
            stdout, _, code = run_kubectl(
                ["get", kind, name, "-o", "yaml"], timeout=15
            )
        else:
            stdout, _, code = run_kubectl(
                ["get", kind, name, "-n", namespace, "-o", "yaml"], timeout=15
            )

        if code == 0 and stdout:
            safe_name = f"{namespace}_{kind.lower()}_{name}.yaml".replace("/", "_")
            bpath = os.path.join(backup_dir, safe_name)
            with open(bpath, "w", encoding="utf-8") as f:
                f.write(stdout)
            ok(f"Backup: {safe_name}")
            backed_up.append(bpath)
        else:
            info(f"Recurso nuevo (sin backup previo): {kind}/{name}")

    return backed_up

# ─── PASO 4: Apply ────────────────────────────────────────────────────────────

def apply_manifest(filepath, dry_run=False):
    step(4, "Aplicando manifiesto")
    args = ["apply", "--server-side", "-f", filepath]
    if dry_run:
        args = ["apply", "--dry-run=client", "-f", filepath]
        warn("[DRY-RUN] Simulando apply...")

    stdout, stderr, code = run_kubectl(args, timeout=60)
    if code == 0:
        ok(f"Apply exitoso:\n{C.DIM}    {stdout}{C.RESET}")
        return True
    else:
        err(f"Apply fallido: {stderr}")
        return False

# ─── PASO 5: Health Check ─────────────────────────────────────────────────────

def health_check(filepath, timeout_secs=300):
    step(5, f"Health Check (rollout status, timeout={timeout_secs}s)")
    resources = extract_resources_from_yaml(filepath)

    all_ok = True
    for kind, name, namespace in resources:
        if kind.lower() not in ("deployment", "statefulset", "daemonset"):
            info(f"Omitiendo health check para {kind}/{name} (no aplica)")
            continue

        info(f"Verificando rollout: {kind}/{name} en {namespace}...")
        stdout, stderr, code = run_kubectl(
            ["rollout", "status", f"{kind.lower()}/{name}",
             "-n", namespace, f"--timeout={timeout_secs}s"],
            timeout=timeout_secs + 10,
        )
        if code == 0:
            ok(f"Rollout completado: {kind}/{name}")
            logger.log("health_check", f"{kind}/{name}", namespace, "OK", stdout)
        else:
            err(f"Rollout fallido o timeout: {kind}/{name}\n    {stderr}")
            logger.log("health_check", f"{kind}/{name}", namespace, "FAILED", stderr)
            all_ok = False

    return all_ok

# ─── PASO 6: Rollback ─────────────────────────────────────────────────────────

def rollback_resource(name, namespace, kind="deployment"):
    step(6, f"⚠ ROLLBACK — {kind}/{name} en {namespace}")
    stdout, stderr, code = run_kubectl(
        ["rollout", "undo", f"{kind}/{name}", "-n", namespace], timeout=30
    )
    if code == 0:
        ok(f"Rollback exitoso: {kind}/{name}")
        logger.log("rollback", f"{kind}/{name}", namespace, "OK", stdout)
    else:
        err(f"Rollback fallido: {stderr}")
        logger.log("rollback", f"{kind}/{name}", namespace, "FAILED", stderr)

def auto_rollback_from_file(filepath, timeout_secs=300):
    """Hace rollback de todos los Deployments de un archivo."""
    resources = extract_resources_from_yaml(filepath)
    for kind, name, namespace in resources:
        if kind.lower() in ("deployment", "statefulset"):
            rollback_resource(name, namespace, kind.lower())

# ─── Flujo principal de deploy ────────────────────────────────────────────────

def deploy_file(filepath, dry_run=False, auto_rollback=False,
                timeout=300, backup_dir=None, confirm=True):
    print(f"\n  {C.BOLD}{'═'*56}{C.RESET}")
    print(f"  {C.BOLD}  Desplegando: {C.CYAN}{os.path.basename(filepath)}{C.RESET}")
    print(f"  {C.BOLD}{'═'*56}{C.RESET}")

    # Paso 1: Validar
    if not validate_yaml(filepath):
        logger.log("validate", filepath, "-", "FAILED")
        return False
    logger.log("validate", filepath, "-", "OK")

    # Paso 2: Diff
    show_diff(filepath)

    # Confirmación interactiva
    if confirm and not dry_run:
        sys.stdout.write(f"\n  {C.YELLOW}¿Proceder con el deploy? [y/N]: {C.RESET}")
        choice = input().strip().lower()
        if choice not in ("y", "yes"):
            warn("Deploy cancelado por el operador")
            return False

    # Paso 3: Backup
    if not dry_run and backup_dir:
        backup_resources(filepath, backup_dir)

    # Paso 4: Apply
    if not apply_manifest(filepath, dry_run=dry_run):
        logger.log("apply", filepath, "-", "FAILED")
        return False
    logger.log("apply", filepath, "-", "OK")

    if dry_run:
        ok("DRY-RUN completado — sin cambios aplicados")
        return True

    # Paso 5: Health check
    passed = health_check(filepath, timeout_secs=timeout)

    if not passed and auto_rollback:
        warn("Health check fallido — iniciando rollback automático...")
        auto_rollback_from_file(filepath, timeout)
        return False

    return passed

# ─── MODO STATUS ──────────────────────────────────────────────────────────────

def cmd_status(args):
    print(f"\n{C.BOLD}{C.CYAN}  Estado de Deployments{C.RESET}")
    print(f"  {'─'*56}")

    kubectl_args = ["get", "deployments", "-o", "wide"]
    if args.namespace:
        kubectl_args += ["-n", args.namespace]
    else:
        kubectl_args += ["--all-namespaces"]

    stdout, stderr, code = run_kubectl(kubectl_args, timeout=20)
    if code == 0:
        print(stdout)
    else:
        err(stderr)

# ─── MODO ROLLBACK MANUAL ─────────────────────────────────────────────────────

def cmd_rollback(args):
    if not args.name or not args.namespace:
        err("--name y --namespace son requeridos para rollback manual")
        sys.exit(1)
    rollback_resource(args.name, args.namespace, kind="deployment")

# ─── PUNTO DE ENTRADA ─────────────────────────────────────────────────────────

def main():
    banner()

    parser = argparse.ArgumentParser(
        description="auto_deploy — Desplegador Kubernetes con Backup y Rollback Automático"
    )

    parser.add_argument("--file",          "-f", help="Archivo YAML a desplegar")
    parser.add_argument("--from-dir",      "-d", help="Directorio con manifiestos YAML a desplegar")
    parser.add_argument("--namespace",     "-n", help="Namespace objetivo (informativo)")
    parser.add_argument("--dry-run",             action="store_true", help="Simular sin aplicar cambios")
    parser.add_argument("--auto-rollback",       action="store_true", help="Rollback automático si falla el health check")
    parser.add_argument("--yes",                 action="store_true", help="No pedir confirmación")
    parser.add_argument("--timeout",       "-t", type=int, default=300, help="Segundos para esperar rollout (default: 300)")
    parser.add_argument("--backup-dir",          default=None, help="Directorio para backups (default: ./backups/<timestamp>)")
    parser.add_argument("--rollback",            action="store_true", help="Hacer rollback manual de un deployment")
    parser.add_argument("--name",          "-N", help="Nombre del deployment (para rollback manual)")
    parser.add_argument("--status",              action="store_true", help="Ver estado de deployments")

    args = parser.parse_args()

    # Verificar conexión al clúster
    if not cluster_reachable():
        err("No se puede conectar al clúster. Verifica tu kubeconfig.")
        sys.exit(1)

    # Modo status
    if args.status:
        cmd_status(args)
        return

    # Modo rollback manual
    if args.rollback:
        cmd_rollback(args)
        return

    # Modo deploy
    if not args.file and not args.from_dir:
        err("Proporciona --file <yaml> o --from-dir <directorio>")
        sys.exit(1)

    ts_str     = datetime.datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    backup_dir = args.backup_dir or f"./backups/{ts_str}"

    files = []
    if args.file:
        if not os.path.exists(args.file):
            err(f"Archivo no encontrado: {args.file}")
            sys.exit(1)
        files = [args.file]
    elif args.from_dir:
        if not os.path.isdir(args.from_dir):
            err(f"Directorio no encontrado: {args.from_dir}")
            sys.exit(1)
        files = list_yaml_files(args.from_dir)
        if not files:
            warn("No se encontraron archivos YAML en el directorio")
            return

    results = {"ok": 0, "failed": 0, "total": len(files)}
    for fpath in files:
        success = deploy_file(
            fpath,
            dry_run=args.dry_run,
            auto_rollback=args.auto_rollback,
            timeout=args.timeout,
            backup_dir=backup_dir if not args.dry_run else None,
            confirm=not args.yes,
        )
        if success:
            results["ok"] += 1
        else:
            results["failed"] += 1

    # Resumen final
    print(f"\n  {'═'*56}")
    print(f"  {C.BOLD}Resumen del Deploy:{C.RESET}")
    print(f"    Total    : {results['total']}")
    print(f"    Exitosos : {C.GREEN}{results['ok']}{C.RESET}")
    print(f"    Fallidos : {C.RED}{results['failed']}{C.RESET}")

    # Guardar log
    if not args.dry_run:
        log_path = logger.save()
        print(f"    Log      : {log_path}")
    print()

if __name__ == "__main__":
    main()

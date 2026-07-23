#!/usr/bin/env python3
"""
yaml_builder.py — Gestor de Manifiestos Kubernetes Cluster-Aware
================================================================
Modos de operación:
  inspect   → Muestra el estado actual de los recursos del clúster
  analyze   → Detecta carencias vs best practices de Kubernetes
  generate  → Genera manifiestos correctivos leyendo los recursos reales del clúster
  new       → Crea un recurso nuevo desde cero con best practices embebidas
  diff      → Muestra qué cambiaría antes de aplicar
  apply     → Aplica los manifiestos generados con backup previo

Uso:
  python3 yaml_builder.py inspect [--namespace NS] [--name NAME]
  python3 yaml_builder.py analyze [--namespace NS] [--name NAME]
  python3 yaml_builder.py generate [--namespace NS] [--name NAME] [--type TYPE] [--output DIR]
  python3 yaml_builder.py new --interactive | --type TYPE --name NAME --namespace NS --image IMG --port PORT
  python3 yaml_builder.py diff [--namespace NS] [--name NAME] [--from-dir DIR]
  python3 yaml_builder.py apply [--namespace NS] [--name NAME] [--from-dir DIR] [--dry-run]
"""

import argparse
import json
import os
import subprocess
import sys
import datetime
import shutil
import textwrap

# ─── Paleta de colores ────────────────────────────────────────────────────────
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

# Namespaces de sistema que NUNCA se tocan automáticamente
SYSTEM_NAMESPACES = {
    "kube-system", "kube-public", "kube-node-lease",
    "calico-system", "calico-apiserver", "tigera-operator",
    "metallb-system", "lens-metrics", "cert-manager",
}

# ─── Utilidades base ──────────────────────────────────────────────────────────

def banner():
    print(f"""
{C.BOLD}{C.CYAN}╔══════════════════════════════════════════════════════════╗
║        yaml_builder — Gestor de Manifiestos K8s          ║
║        Cluster-Aware · Best Practices · Safe Apply       ║
╚══════════════════════════════════════════════════════════╝{C.RESET}
""")

def ok(msg):  print(f"  {C.GREEN}✓{C.RESET} {msg}")
def warn(msg): print(f"  {C.YELLOW}⚠{C.RESET}  {msg}")
def err(msg):  print(f"  {C.RED}✗{C.RESET} {msg}")
def info(msg): print(f"  {C.BLUE}→{C.RESET} {msg}")
def section(title):
    print(f"\n{C.BOLD}{C.WHITE}{'─'*60}{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}  {title}{C.RESET}")
    print(f"{C.BOLD}{C.WHITE}{'─'*60}{C.RESET}")

def run_kubectl(args, timeout=20):
    """Ejecuta kubectl y retorna (stdout, stderr, returncode)."""
    cmd = ["kubectl"] + args
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
        return "", "kubectl no encontrado en PATH", -1
    except subprocess.TimeoutExpired:
        proc.kill(); proc.communicate()
        return "", "Timeout ejecutando kubectl", -1
    except Exception as e:
        return "", str(e), -1

def kubectl_available():
    stdout, _, code = run_kubectl(["version", "--client", "--output=json"])
    return code == 0

def cluster_reachable():
    _, _, code = run_kubectl(["cluster-info", "--request-timeout=5s"])
    return code == 0

def get_namespaces(exclude_system=True):
    stdout, _, code = run_kubectl(["get", "namespaces", "-o", "json"])
    if code != 0:
        return []
    data = json.loads(stdout)
    ns_list = [ns["metadata"]["name"] for ns in data.get("items", [])]
    if exclude_system:
        ns_list = [n for n in ns_list if n not in SYSTEM_NAMESPACES]
    return ns_list

def get_deployments(namespace=None):
    args = ["get", "deployments", "-o", "json"]
    if namespace:
        args += ["-n", namespace]
    else:
        args += ["--all-namespaces"]
    stdout, _, code = run_kubectl(args, timeout=30)
    if code != 0:
        return []
    data = json.loads(stdout)
    return data.get("items", [])

def get_hpas(namespace=None):
    args = ["get", "hpa", "-o", "json"]
    if namespace:
        args += ["-n", namespace]
    else:
        args += ["--all-namespaces"]
    stdout, _, code = run_kubectl(args, timeout=20)
    if code != 0:
        return []
    data = json.loads(stdout)
    return data.get("items", [])

def get_pdbs(namespace=None):
    args = ["get", "pdb", "-o", "json"]
    if namespace:
        args += ["-n", namespace]
    else:
        args += ["--all-namespaces"]
    stdout, _, code = run_kubectl(args, timeout=20)
    if code != 0:
        return []
    data = json.loads(stdout)
    return data.get("items", [])

def get_networkpolicies(namespace=None):
    args = ["get", "networkpolicies", "-o", "json"]
    if namespace:
        args += ["-n", namespace]
    else:
        args += ["--all-namespaces"]
    stdout, _, code = run_kubectl(args, timeout=20)
    if code != 0:
        return []
    data = json.loads(stdout)
    return data.get("items", [])

# ─── Análisis de un Deployment ───────────────────────────────────────────────

def analyze_deployment(dep):
    """Analiza un Deployment y retorna lista de hallazgos."""
    name      = dep["metadata"]["name"]
    namespace = dep["metadata"]["namespace"]
    findings  = []

    spec      = dep.get("spec", {})
    replicas  = spec.get("replicas", 1)
    template  = spec.get("template", {})
    pod_spec  = template.get("spec", {})
    containers = pod_spec.get("containers", [])
    strategy  = spec.get("strategy", {}).get("type", "RollingUpdate")
    affinity  = pod_spec.get("affinity", {})

    # ── Estrategia de actualización
    if strategy == "Recreate":
        findings.append(("CRITICAL", "Estrategia 'Recreate' causa downtime en cada deploy"))

    # ── Réplicas únicas
    if replicas < 2:
        findings.append(("WARNING", f"Réplicas: {replicas} — Punto único de fallo (SPOF)"))

    # ── podAntiAffinity
    if not affinity.get("podAntiAffinity"):
        findings.append(("WARNING", "Sin podAntiAffinity — réplicas pueden caer en el mismo nodo"))

    for c in containers:
        cname = c.get("name", "?")
        prefix = f"[{cname}]"

        # ── Resources
        resources = c.get("resources", {})
        requests  = resources.get("requests", {})
        limits    = resources.get("limits", {})

        if not requests.get("cpu") or not requests.get("memory"):
            findings.append(("CRITICAL", f"{prefix} Sin resource requests (QoS: BestEffort)"))
        if not limits.get("cpu") or not limits.get("memory"):
            findings.append(("WARNING", f"{prefix} Sin resource limits — riesgo de DoS en el nodo"))
        if not limits.get("ephemeral-storage"):
            findings.append(("WARNING", f"{prefix} Sin límite ephemeral-storage — riesgo DiskPressure"))

        # ── Health Probes
        if not c.get("livenessProbe"):
            findings.append(("CRITICAL", f"{prefix} Sin livenessProbe — K8s no puede detectar deadlocks"))
        if not c.get("readinessProbe"):
            findings.append(("CRITICAL", f"{prefix} Sin readinessProbe — tráfico llega a pods no listos"))

        # ── Security Context
        sc = c.get("securityContext", {})
        if not sc.get("runAsNonRoot"):
            findings.append(("WARNING", f"{prefix} Sin runAsNonRoot — contenedor puede correr como root"))
        if sc.get("privileged"):
            findings.append(("CRITICAL", f"{prefix} Modo PRIVILEGIADO activo — acceso total al kernel del host"))
        if sc.get("allowPrivilegeEscalation") is not False:
            findings.append(("WARNING", f"{prefix} allowPrivilegeEscalation no es false"))
        if not sc.get("readOnlyRootFilesystem"):
            findings.append(("WARNING", f"{prefix} readOnlyRootFilesystem no está activado"))

    return findings

def get_qos_class(dep):
    """Determina la clase QoS de un Deployment basándose en sus containers."""
    containers = dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
    has_limits = all(
        c.get("resources", {}).get("limits", {}).get("cpu") and
        c.get("resources", {}).get("limits", {}).get("memory")
        for c in containers
    )
    has_requests = all(
        c.get("resources", {}).get("requests", {}).get("cpu") and
        c.get("resources", {}).get("requests", {}).get("memory")
        for c in containers
    )
    if not has_requests and not has_limits:
        return "BestEffort"
    if has_limits and has_requests:
        req_eq_lim = all(
            c.get("resources", {}).get("requests", {}).get("cpu") ==
            c.get("resources", {}).get("limits", {}).get("cpu") and
            c.get("resources", {}).get("requests", {}).get("memory") ==
            c.get("resources", {}).get("limits", {}).get("memory")
            for c in containers
        )
        return "Guaranteed" if req_eq_lim else "Burstable"
    return "Burstable"

# ─── MODO INSPECT ─────────────────────────────────────────────────────────────

def cmd_inspect(args):
    section("INSPECT — Estado Actual del Clúster")

    deployments = get_deployments(args.namespace)
    if args.name:
        deployments = [d for d in deployments if d["metadata"]["name"] == args.name]

    hpas = {
        (h["metadata"]["namespace"],
         h["spec"]["scaleTargetRef"]["name"]): h
        for h in get_hpas(args.namespace)
    }
    pdbs_raw = get_pdbs(args.namespace)
    pdb_targets = set()
    for p in pdbs_raw:
        selector = p.get("spec", {}).get("selector", {}).get("matchLabels", {})
        ns = p["metadata"]["namespace"]
        for dep in deployments:
            dep_labels = dep.get("spec", {}).get("selector", {}).get("matchLabels", {})
            if selector and selector == dep_labels and dep["metadata"]["namespace"] == ns:
                pdb_targets.add((ns, dep["metadata"]["name"]))

    netpols = {np["metadata"]["namespace"] for np in get_networkpolicies(args.namespace)}

    # Header tabla
    col_w = [32, 22, 5, 12, 7, 7, 4, 4, 10]
    headers = ["NOMBRE", "NAMESPACE", "REP.", "QoS", "PROBES", "RESRCS", "HPA", "PDB", "NETPOL"]
    sep = "─" * sum(col_w + [len(headers)*3])

    print(f"\n{C.BOLD}", end="")
    for h, w in zip(headers, col_w):
        print(f"  {h:<{w}}", end="")
    print(C.RESET)
    print(f"  {sep}")

    if not deployments:
        warn("No se encontraron Deployments con los filtros aplicados.")
        return

    for dep in deployments:
        name      = dep["metadata"]["name"]
        namespace = dep["metadata"]["namespace"]
        if namespace in SYSTEM_NAMESPACES:
            continue
        replicas  = dep.get("spec", {}).get("replicas", 1)
        qos       = get_qos_class(dep)
        findings  = analyze_deployment(dep)

        crit_count = sum(1 for f in findings if f[0] == "CRITICAL")
        warn_count = sum(1 for f in findings if f[0] == "WARNING")

        has_hpa    = (namespace, name) in hpas
        has_pdb    = (namespace, name) in pdb_targets
        has_netpol = namespace in netpols

        containers = dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        has_probes = all(c.get("livenessProbe") and c.get("readinessProbe") for c in containers)
        has_resources = all(
            c.get("resources", {}).get("requests") and c.get("resources", {}).get("limits")
            for c in containers
        )

        # Colores por severidad
        if crit_count > 0:
            row_color = C.RED
        elif warn_count > 0:
            row_color = C.YELLOW
        else:
            row_color = C.GREEN

        probes_str   = f"{C.GREEN}✓{C.RESET}" if has_probes   else f"{C.RED}✗{C.RESET}"
        resrcs_str   = f"{C.GREEN}✓{C.RESET}" if has_resources else f"{C.RED}✗{C.RESET}"
        hpa_str      = f"{C.GREEN}✓{C.RESET}" if has_hpa      else f"{C.RED}✗{C.RESET}"
        pdb_str      = f"{C.GREEN}✓{C.RESET}" if has_pdb      else f"{C.RED}✗{C.RESET}"
        netpol_str   = f"{C.GREEN}✓{C.RESET}" if has_netpol   else f"{C.RED}✗{C.RESET}"

        qos_color = {
            "Guaranteed": C.GREEN,
            "Burstable":  C.YELLOW,
            "BestEffort": C.RED,
        }.get(qos, C.WHITE)

        print(
            f"  {row_color}{name:<{col_w[0]}}{C.RESET}"
            f"  {namespace:<{col_w[1]}}"
            f"  {replicas:<{col_w[2]}}"
            f"  {qos_color}{qos:<{col_w[3]}}{C.RESET}"
            f"  {probes_str}      "
            f"  {resrcs_str}      "
            f"  {hpa_str}   "
            f"  {pdb_str}   "
            f"  {netpol_str}"
        )

    print(f"\n  {C.DIM}Leyenda: ✓ = OK  ✗ = Faltante  REP.=Réplicas{C.RESET}")
    print(f"  {C.DIM}Tip: usa 'analyze' para ver el detalle de cada hallazgo.{C.RESET}\n")

# ─── MODO ANALYZE ─────────────────────────────────────────────────────────────

def cmd_analyze(args):
    section("ANALYZE — Carencias vs Best Practices de Kubernetes")

    deployments = get_deployments(args.namespace)
    if args.name:
        deployments = [d for d in deployments if d["metadata"]["name"] == args.name]

    total_critical = 0
    total_warning  = 0
    affected_deps  = 0

    for dep in deployments:
        name      = dep["metadata"]["name"]
        namespace = dep["metadata"]["namespace"]
        if namespace in SYSTEM_NAMESPACES:
            continue

        findings = analyze_deployment(dep)
        if not findings:
            continue

        affected_deps += 1
        crit = [f for f in findings if f[0] == "CRITICAL"]
        warns = [f for f in findings if f[0] == "WARNING"]
        total_critical += len(crit)
        total_warning  += len(warns)

        label_color = C.RED if crit else C.YELLOW
        print(f"\n  {label_color}{C.BOLD}DEPLOYMENT:{C.RESET} {C.BOLD}{name}{C.RESET} {C.DIM}({namespace}){C.RESET}")
        for _, msg in crit:
            print(f"    {C.RED}🔴 {msg}{C.RESET}")
        for _, msg in warns:
            print(f"    {C.YELLOW}⚠️  {msg}{C.RESET}")

    print(f"\n  {'─'*60}")
    print(f"  {C.BOLD}Resumen:{C.RESET}")
    print(f"    Deployments afectados : {C.BOLD}{affected_deps}{C.RESET}")
    print(f"    Hallazgos críticos    : {C.RED}{C.BOLD}{total_critical}{C.RESET}")
    print(f"    Advertencias          : {C.YELLOW}{C.BOLD}{total_warning}{C.RESET}")
    if total_critical == 0 and total_warning == 0:
        ok("¡Todos los recursos cumplen las best practices!")
    else:
        print(f"\n  {C.DIM}Tip: usa 'generate' para crear manifiestos correctivos automáticamente.{C.RESET}\n")

# ─── GENERADORES DE YAML ──────────────────────────────────────────────────────

def detect_probe_port(container):
    """Intenta detectar el puerto del contenedor para las probes."""
    ports = container.get("ports", [])
    if ports:
        return ports[0].get("containerPort", 8080)
    return 8080

def generate_hpa_yaml(name, namespace, min_r=2, max_r=8, cpu_pct=80, mem_pct=85):
    return f"""\
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {name}
  namespace: {namespace}
  labels:
    app.kubernetes.io/name: {name}
    app.kubernetes.io/managed-by: yaml-builder
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {name}
  minReplicas: {min_r}
  maxReplicas: {max_r}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {cpu_pct}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {mem_pct}
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 2
          periodSeconds: 60
"""

def generate_pdb_yaml(name, namespace, min_available=1):
    dep_label_selector = name
    return f"""\
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {name}-pdb
  namespace: {namespace}
  labels:
    app.kubernetes.io/name: {name}
    app.kubernetes.io/managed-by: yaml-builder
spec:
  minAvailable: {min_available}
  selector:
    matchLabels:
      app: {dep_label_selector}
"""

def generate_networkpolicy_yaml(namespace):
    return f"""\
# NetworkPolicy: deny-all-ingress (default deny)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: {namespace}
  labels:
    app.kubernetes.io/managed-by: yaml-builder
spec:
  podSelector: {{}}
  policyTypes:
    - Ingress
---
# NetworkPolicy: allow-ingress-from-ingress-nginx
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ingress-nginx
  namespace: {namespace}
  labels:
    app.kubernetes.io/managed-by: yaml-builder
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
# NetworkPolicy: allow-intra-namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-namespace
  namespace: {namespace}
  labels:
    app.kubernetes.io/managed-by: yaml-builder
spec:
  podSelector: {{}}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {{}}
"""

def generate_deployment_patch_yaml(dep, output_dir=None):
    """Genera un YAML de patch para un Deployment existente con las best practices faltantes."""
    name      = dep["metadata"]["name"]
    namespace = dep["metadata"]["namespace"]
    spec      = dep.get("spec", {})
    template  = spec.get("template", {})
    pod_spec  = template.get("spec", {})
    containers = pod_spec.get("containers", [])
    replicas  = spec.get("replicas", 1)
    strategy  = spec.get("strategy", {}).get("type", "RollingUpdate")

    patched_containers = []
    for c in containers:
        cname = c.get("name", "container")
        port  = detect_probe_port(c)
        resources = c.get("resources", {})
        requests  = resources.get("requests", {})
        limits    = resources.get("limits", {})
        sc        = c.get("securityContext", {})

        # Construimos el patch del container
        new_resources = {
            "requests": {
                "cpu":               requests.get("cpu",    "100m"),
                "memory":            requests.get("memory", "128Mi"),
                "ephemeral-storage": requests.get("ephemeral-storage", "100Mi"),
            },
            "limits": {
                "cpu":               limits.get("cpu",    "500m"),
                "memory":            limits.get("memory", "512Mi"),
                "ephemeral-storage": limits.get("ephemeral-storage", "500Mi"),
            },
        }

        # Probe solo si faltan
        probe_block = ""
        if not c.get("livenessProbe") or not c.get("readinessProbe"):
            probe_block = f"""\
        livenessProbe:
          httpGet:
            path: /
            port: {port}
          initialDelaySeconds: 30
          periodSeconds: 15
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /
            port: {port}
          initialDelaySeconds: 15
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3"""

        sc_block = f"""\
        securityContext:
          runAsNonRoot: {str(sc.get('runAsNonRoot', True)).lower()}
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          capabilities:
            drop:
              - ALL"""

        patched_containers.append((cname, new_resources, probe_block, sc_block))

    # Construir YAML completo
    strategy_block = ""
    if strategy == "Recreate":
        strategy_block = """\
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0"""

    replicas_block = ""
    if replicas < 2:
        replicas_block = f"  replicas: 2"

    affinity_block = ""
    if not pod_spec.get("affinity", {}).get("podAntiAffinity"):
        affinity_block = f"""\
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: {name}
                topologyKey: kubernetes.io/hostname"""

    containers_block = ""
    for cname, res, probe_b, sc_b in patched_containers:
        containers_block += f"""\
      - name: {cname}
        resources:
          requests:
            cpu: "{res['requests']['cpu']}"
            memory: "{res['requests']['memory']}"
            ephemeral-storage: "{res['requests']['ephemeral-storage']}"
          limits:
            cpu: "{res['limits']['cpu']}"
            memory: "{res['limits']['memory']}"
            ephemeral-storage: "{res['limits']['ephemeral-storage']}"
"""
        if probe_b:
            containers_block += probe_b + "\n"
        containers_block += sc_b + "\n"

    yaml_content = f"""\
# Manifiesto correctivo generado por yaml_builder
# Deployment: {name} | Namespace: {namespace}
# Generado: {datetime.datetime.utcnow().isoformat()}Z
# NOTA: Revisa los valores de resources, ports y paths de probes antes de aplicar.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
  namespace: {namespace}
  labels:
    app.kubernetes.io/name: {name}
    app.kubernetes.io/managed-by: yaml-builder
spec:
{replicas_block}
{strategy_block}
  selector:
    matchLabels:
      app: {name}
  template:
    metadata:
      labels:
        app: {name}
        app.kubernetes.io/name: {name}
    spec:
{affinity_block}
      containers:
{containers_block}"""

    return yaml_content

def generate_new_deployment_yaml(name, namespace, image, port, cpu_req="100m", cpu_lim="500m",
                                  mem_req="128Mi", mem_lim="512Mi", replicas=2,
                                  probe_path="/", probe_type="http"):
    probe_def = ""
    if probe_type == "http":
        probe_def = f"""\
          httpGet:
            path: {probe_path}
            port: {port}"""
    elif probe_type == "tcp":
        probe_def = f"""\
          tcpSocket:
            port: {port}"""
    else:
        probe_def = f"""\
          exec:
            command: ["/bin/sh", "-c", "echo ok"]"""

    return f"""\
# Manifiesto generado por yaml_builder — Best Practices K8s
# Generado: {datetime.datetime.utcnow().isoformat()}Z
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
  namespace: {namespace}
  labels:
    app.kubernetes.io/name: {name}
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: yaml-builder
spec:
  replicas: {replicas}
  selector:
    matchLabels:
      app: {name}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: {name}
        app.kubernetes.io/name: {name}
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: {name}
                topologyKey: kubernetes.io/hostname
      containers:
        - name: {name}
          image: {image}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: {port}
              protocol: TCP
          resources:
            requests:
              cpu: "{cpu_req}"
              memory: "{mem_req}"
              ephemeral-storage: "100Mi"
            limits:
              cpu: "{cpu_lim}"
              memory: "{mem_lim}"
              ephemeral-storage: "500Mi"
          livenessProbe:
{probe_def}
            initialDelaySeconds: 30
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
{probe_def}
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop:
                - ALL
          env: []
          envFrom: []
      terminationGracePeriodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: {name}
  namespace: {namespace}
  labels:
    app.kubernetes.io/name: {name}
    app.kubernetes.io/managed-by: yaml-builder
spec:
  selector:
    app: {name}
  ports:
    - name: http
      port: {port}
      targetPort: {port}
      protocol: TCP
  type: ClusterIP
"""

# ─── MODO GENERATE ────────────────────────────────────────────────────────────

def cmd_generate(args):
    section("GENERATE — Manifiestos Correctivos desde el Clúster")

    output_dir = args.output or "./manifests"
    os.makedirs(output_dir, exist_ok=True)

    gen_type = args.type or "all"
    deployments = get_deployments(args.namespace)
    if args.name:
        deployments = [d for d in deployments if d["metadata"]["name"] == args.name]

    # Obtener HPAs y PDBs existentes
    existing_hpas = {
        (h["metadata"]["namespace"], h["spec"]["scaleTargetRef"]["name"])
        for h in get_hpas(args.namespace)
    }
    existing_pdbs_ns = {p["metadata"]["namespace"] for p in get_pdbs(args.namespace)}
    existing_netpols_ns = {np["metadata"]["namespace"] for np in get_networkpolicies(args.namespace)}

    namespaces_processed = set()
    files_generated = []

    for dep in deployments:
        name      = dep["metadata"]["name"]
        namespace = dep["metadata"]["namespace"]
        if namespace in SYSTEM_NAMESPACES:
            continue

        findings = analyze_deployment(dep)
        if not findings and gen_type == "all":
            ok(f"{name} ({namespace}) — sin carencias, omitido")
            continue

        info(f"Generando para: {C.BOLD}{name}{C.RESET} ({namespace})")

        # ── Deployment patch
        if gen_type in ("all", "deployment"):
            fname = os.path.join(output_dir, f"{namespace}_{name}_patch.yaml")
            content = generate_deployment_patch_yaml(dep)
            with open(fname, "w", encoding="utf-8") as f:
                f.write(content)
            ok(f"  → {fname}")
            files_generated.append(fname)

        # ── HPA
        if gen_type in ("all", "hpa"):
            if (namespace, name) not in existing_hpas:
                fname = os.path.join(output_dir, f"{namespace}_{name}_hpa.yaml")
                with open(fname, "w", encoding="utf-8") as f:
                    f.write(generate_hpa_yaml(name, namespace))
                ok(f"  → {fname}")
                files_generated.append(fname)
            else:
                info(f"  HPA ya existe para {name}, omitido")

        # ── PDB
        if gen_type in ("all", "pdb"):
            replicas = dep.get("spec", {}).get("replicas", 1)
            if replicas >= 2:
                fname = os.path.join(output_dir, f"{namespace}_{name}_pdb.yaml")
                with open(fname, "w", encoding="utf-8") as f:
                    f.write(generate_pdb_yaml(name, namespace))
                ok(f"  → {fname}")
                files_generated.append(fname)

        # ── NetworkPolicy (una por namespace)
        if gen_type in ("all", "networkpolicy"):
            if namespace not in namespaces_processed and namespace not in existing_netpols_ns:
                fname = os.path.join(output_dir, f"{namespace}_networkpolicy.yaml")
                with open(fname, "w", encoding="utf-8") as f:
                    f.write(generate_networkpolicy_yaml(namespace))
                ok(f"  → {fname} (NetworkPolicy para namespace {namespace})")
                files_generated.append(fname)
                namespaces_processed.add(namespace)

    print(f"\n  {C.BOLD}Total archivos generados:{C.RESET} {C.GREEN}{len(files_generated)}{C.RESET}")
    print(f"  {C.BOLD}Directorio de salida  :{C.RESET} {output_dir}")
    print(f"\n  {C.DIM}Tip: Revisa los valores de resources y probe paths antes de aplicar.")
    print(f"  Usa 'diff' para ver exactamente qué cambiaría en el clúster.{C.RESET}\n")

# ─── MODO NEW ─────────────────────────────────────────────────────────────────

def cmd_new(args):
    section("NEW — Crear Recurso desde Cero con Best Practices")

    if args.interactive:
        print(f"\n  {C.CYAN}Modo interactivo — responde las siguientes preguntas:{C.RESET}\n")

        def ask(prompt, default=None):
            if default:
                sys.stdout.write(f"  {C.BOLD}{prompt}{C.RESET} [{C.DIM}{default}{C.RESET}]: ")
            else:
                sys.stdout.write(f"  {C.BOLD}{prompt}{C.RESET}: ")
            sys.stdout.flush()
            val = input().strip()
            return val if val else default

        res_type  = ask("Tipo de recurso (deployment/hpa/pdb/networkpolicy)", "deployment")
        name      = ask("Nombre del recurso")
        namespace = ask("Namespace", "default")

        if not name:
            err("El nombre es obligatorio.")
            sys.exit(1)

        output_dir = args.output or "./manifests"
        os.makedirs(output_dir, exist_ok=True)

        if res_type in ("deployment", "all"):
            image      = ask("Imagen Docker (image:tag)", f"registry.example.com/{name}:latest")
            port       = int(ask("Puerto del contenedor", "8080"))
            probe_type = ask("Tipo de health probe (http/tcp/exec)", "http")
            probe_path = ask("Path del health check (solo http)", "/")
            cpu_req    = ask("CPU request", "100m")
            cpu_lim    = ask("CPU limit",   "500m")
            mem_req    = ask("Memoria request", "128Mi")
            mem_lim    = ask("Memoria limit",   "512Mi")
            replicas   = int(ask("Número de réplicas", "2"))

            content = generate_new_deployment_yaml(
                name, namespace, image, port,
                cpu_req, cpu_lim, mem_req, mem_lim,
                replicas, probe_path, probe_type
            )
            fname = os.path.join(output_dir, f"{namespace}_{name}_new.yaml")
            with open(fname, "w", encoding="utf-8") as f:
                f.write(content)
            ok(f"Deployment generado: {fname}")

        if res_type in ("hpa", "all"):
            min_r   = int(ask("Réplicas mínimas HPA", "2"))
            max_r   = int(ask("Réplicas máximas HPA", "8"))
            cpu_pct = int(ask("CPU % objetivo HPA",   "80"))
            content = generate_hpa_yaml(name, namespace, min_r, max_r, cpu_pct)
            fname = os.path.join(output_dir, f"{namespace}_{name}_hpa.yaml")
            with open(fname, "w", encoding="utf-8") as f:
                f.write(content)
            ok(f"HPA generado: {fname}")

        if res_type in ("pdb", "all"):
            min_avail = int(ask("minAvailable para PDB", "1"))
            content = generate_pdb_yaml(name, namespace, min_avail)
            fname = os.path.join(output_dir, f"{namespace}_{name}_pdb.yaml")
            with open(fname, "w", encoding="utf-8") as f:
                f.write(content)
            ok(f"PDB generado: {fname}")

        if res_type in ("networkpolicy", "all"):
            content = generate_networkpolicy_yaml(namespace)
            fname = os.path.join(output_dir, f"{namespace}_networkpolicy.yaml")
            with open(fname, "w", encoding="utf-8") as f:
                f.write(content)
            ok(f"NetworkPolicy generada: {fname}")

    else:
        # Modo directo por flags
        name      = args.name
        namespace = args.namespace or "default"
        res_type  = args.type or "deployment"

        if not name:
            err("--name es obligatorio en modo no-interactivo.")
            sys.exit(1)

        output_dir = args.output or "./manifests"
        os.makedirs(output_dir, exist_ok=True)

        if res_type in ("deployment",):
            if not args.image:
                err("--image es obligatorio para tipo deployment.")
                sys.exit(1)
            content = generate_new_deployment_yaml(
                name, namespace, args.image, args.port or 8080,
                args.cpu_request or "100m", args.cpu_limit or "500m",
                args.mem_request or "128Mi", args.mem_limit or "512Mi",
                args.replicas or 2,
                args.probe_path or "/",
                args.probe_type or "http",
            )
            fname = os.path.join(output_dir, f"{namespace}_{name}_new.yaml")
            with open(fname, "w", encoding="utf-8") as f:
                f.write(content)
            ok(f"Deployment generado: {fname}")

        elif res_type == "hpa":
            content = generate_hpa_yaml(name, namespace)
            fname = os.path.join(output_dir, f"{namespace}_{name}_hpa.yaml")
            with open(fname, "w", encoding="utf-8") as f:
                f.write(content)
            ok(f"HPA generado: {fname}")

        elif res_type == "pdb":
            content = generate_pdb_yaml(name, namespace)
            fname = os.path.join(output_dir, f"{namespace}_{name}_pdb.yaml")
            with open(fname, "w", encoding="utf-8") as f:
                f.write(content)
            ok(f"PDB generado: {fname}")

        elif res_type == "networkpolicy":
            content = generate_networkpolicy_yaml(namespace)
            fname = os.path.join(output_dir, f"{namespace}_networkpolicy.yaml")
            with open(fname, "w", encoding="utf-8") as f:
                f.write(content)
            ok(f"NetworkPolicy generada: {fname}")

        else:
            err(f"Tipo '{res_type}' no reconocido. Usa: deployment, hpa, pdb, networkpolicy")
            sys.exit(1)

    print(f"\n  {C.DIM}Tip: usa 'diff' para ver qué cambiaría antes de aplicar.{C.RESET}\n")

# ─── MODO DIFF ────────────────────────────────────────────────────────────────

def cmd_diff(args):
    section("DIFF — Comparar Manifiestos con Estado Actual del Clúster")

    files = []
    if args.from_dir:
        if not os.path.isdir(args.from_dir):
            err(f"Directorio no encontrado: {args.from_dir}")
            sys.exit(1)
        files = [
            os.path.join(args.from_dir, f)
            for f in os.listdir(args.from_dir)
            if f.endswith(".yaml") or f.endswith(".yml")
        ]
    elif args.name and args.namespace:
        # Generar en temp y hacer diff
        import tempfile
        deps = get_deployments(args.namespace)
        dep  = next((d for d in deps if d["metadata"]["name"] == args.name), None)
        if not dep:
            err(f"Deployment '{args.name}' no encontrado en namespace '{args.namespace}'")
            sys.exit(1)
        content = generate_deployment_patch_yaml(dep)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as tf:
            tf.write(content)
            files = [tf.name]
    else:
        err("Proporciona --from-dir o --name + --namespace")
        sys.exit(1)

    for fpath in files:
        info(f"Diff para: {fpath}")
        stdout, stderr, code = run_kubectl(["diff", "-f", fpath], timeout=30)
        if code == 0:
            ok("Sin cambios (el clúster ya está al día)")
        elif code == 1:
            # kubectl diff retorna 1 cuando hay diferencias (comportamiento normal)
            print(stdout if stdout else "(sin output de diff)")
        else:
            warn(f"kubectl diff retornó código {code}: {stderr}")

# ─── MODO APPLY ───────────────────────────────────────────────────────────────

def cmd_apply(args):
    section("APPLY — Aplicar Manifiestos con Backup Previo")

    dry_run = args.dry_run
    if dry_run:
        warn("MODO DRY-RUN — No se aplicará ningún cambio")

    files = []
    if args.from_dir:
        if not os.path.isdir(args.from_dir):
            err(f"Directorio no encontrado: {args.from_dir}")
            sys.exit(1)
        files = sorted([
            os.path.join(args.from_dir, f)
            for f in os.listdir(args.from_dir)
            if f.endswith(".yaml") or f.endswith(".yml")
        ])
    else:
        err("Usa --from-dir para indicar el directorio con manifiestos a aplicar")
        sys.exit(1)

    backup_dir = f"./backups/{datetime.datetime.utcnow().strftime('%Y%m%d_%H%M%S')}"
    if not dry_run:
        os.makedirs(backup_dir, exist_ok=True)
        info(f"Backups en: {backup_dir}")

    for fpath in files:
        fname = os.path.basename(fpath)
        print(f"\n  {C.BOLD}▶ Procesando:{C.RESET} {fname}")

        # Validación dry-run client
        _, stderr, code = run_kubectl(["apply", "--dry-run=client", "-f", fpath], timeout=30)
        if code != 0:
            err(f"Validación fallida: {stderr}")
            continue
        ok("Validación pre-apply: OK")

        if dry_run:
            info(f"[DRY-RUN] kubectl apply -f {fpath}")
            continue

        # Confirmación interactiva
        if not args.yes:
            sys.stdout.write(f"  {C.YELLOW}¿Aplicar '{fname}'? [y/N]: {C.RESET}")
            choice = input().strip().lower()
            if choice not in ("y", "yes"):
                warn("Omitido por el operador")
                continue

        # Apply real
        stdout, stderr, code = run_kubectl(["apply", "--server-side", "-f", fpath], timeout=60)
        if code == 0:
            ok(f"Aplicado: {stdout}")
        else:
            err(f"Falló: {stderr}")

    if not dry_run:
        print(f"\n  {C.DIM}Backups guardados en: {backup_dir}{C.RESET}")
    print()

# ─── PUNTO DE ENTRADA ─────────────────────────────────────────────────────────

def main():
    banner()

    parser = argparse.ArgumentParser(
        description="yaml_builder — Gestor de Manifiestos Kubernetes Cluster-Aware",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # ── inspect
    p_inspect = sub.add_parser("inspect", help="Ver estado actual de recursos en el clúster")
    p_inspect.add_argument("--namespace", "-n", help="Namespace a inspeccionar (omitir = todos)")
    p_inspect.add_argument("--name",      "-N", help="Nombre del Deployment específico")

    # ── analyze
    p_analyze = sub.add_parser("analyze", help="Detectar carencias vs best practices")
    p_analyze.add_argument("--namespace", "-n")
    p_analyze.add_argument("--name",      "-N")

    # ── generate
    p_generate = sub.add_parser("generate", help="Generar manifiestos correctivos desde el clúster")
    p_generate.add_argument("--namespace", "-n")
    p_generate.add_argument("--name",      "-N")
    p_generate.add_argument("--type",      "-t", choices=["all","deployment","hpa","pdb","networkpolicy"], default="all")
    p_generate.add_argument("--output",    "-o", default="./manifests")

    # ── new
    p_new = sub.add_parser("new", help="Crear recurso desde cero con best practices")
    p_new.add_argument("--interactive", "-i", action="store_true")
    p_new.add_argument("--type",        "-t", choices=["deployment","hpa","pdb","networkpolicy","all"])
    p_new.add_argument("--name",        "-N")
    p_new.add_argument("--namespace",   "-n", default="default")
    p_new.add_argument("--image")
    p_new.add_argument("--port",        type=int, default=8080)
    p_new.add_argument("--probe-type",  choices=["http","tcp","exec"], default="http")
    p_new.add_argument("--probe-path",  default="/")
    p_new.add_argument("--cpu-request", default="100m")
    p_new.add_argument("--cpu-limit",   default="500m")
    p_new.add_argument("--mem-request", default="128Mi")
    p_new.add_argument("--mem-limit",   default="512Mi")
    p_new.add_argument("--replicas",    type=int, default=2)
    p_new.add_argument("--output",      "-o", default="./manifests")

    # ── diff
    p_diff = sub.add_parser("diff", help="Ver qué cambiaría en el clúster antes de aplicar")
    p_diff.add_argument("--namespace",  "-n")
    p_diff.add_argument("--name",       "-N")
    p_diff.add_argument("--from-dir",   "-d")

    # ── apply
    p_apply = sub.add_parser("apply", help="Aplicar manifiestos con backup y validación")
    p_apply.add_argument("--namespace",  "-n")
    p_apply.add_argument("--from-dir",   "-d", required=True)
    p_apply.add_argument("--dry-run",    action="store_true")
    p_apply.add_argument("--yes",        action="store_true", help="No pedir confirmación")

    args = parser.parse_args()

    # Verificar prerequisitos
    if not kubectl_available():
        err("kubectl no encontrado en PATH. Instálalo y asegúrate de que esté en PATH.")
        sys.exit(1)

    if args.command not in ("new",) and not cluster_reachable():
        err("No se puede conectar al clúster. Verifica tu kubeconfig.")
        sys.exit(1)

    dispatch = {
        "inspect":  cmd_inspect,
        "analyze":  cmd_analyze,
        "generate": cmd_generate,
        "new":      cmd_new,
        "diff":     cmd_diff,
        "apply":    cmd_apply,
    }
    dispatch[args.command](args)

if __name__ == "__main__":
    main()

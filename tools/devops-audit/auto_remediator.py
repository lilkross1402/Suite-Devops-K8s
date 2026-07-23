#!/usr/bin/env python3
import json
import sys
import subprocess
import argparse
import os
import re

class Colors:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'

def print_header(text):
    print(f"\n{Colors.BOLD}{Colors.HEADER}=== {text} ==={Colors.ENDC}")

def prompt_user(prompt_text, auto_approve=False):
    if auto_approve:
        print(f"{Colors.OKCYAN}{prompt_text} [AUTO-APPROVED]{Colors.ENDC}")
        return True
    while True:
        sys.stdout.write(f"{Colors.WARNING}{prompt_text} [y/N]: {Colors.ENDC}")
        choice = input().strip().lower()
        if choice in ['y', 'yes']:
            return True
        elif choice in ['n', 'no', '']:
            return False
        else:
            print("Por favor responde 'y' o 'n'.")

def run_cmd(cmd, dry_run=False):
    if dry_run:
        print(f"  {Colors.OKBLUE}[DRY-RUN]{Colors.ENDC} Ejecutaría: {cmd}")
        return True
    
    print(f"  {Colors.OKBLUE}[EJECUTANDO]{Colors.ENDC} {cmd}...")
    try:
        proc = subprocess.Popen(
            cmd,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        stdout, stderr = proc.communicate()
        if proc.returncode == 0:
            print(f"  {Colors.OKGREEN}✓ Éxito.{Colors.ENDC} {stdout.strip()}")
            return True
        else:
            print(f"  {Colors.FAIL}✗ Falló.{Colors.ENDC} {stderr.strip()}")
            return False
    except Exception as e:
        print(f"  {Colors.FAIL}✗ Error en ejecución:{Colors.ENDC} {e}")
        return False

def parse_ns_name(entry_str):
    m = re.match(r'(.+?)\s+\((.+?)\)', entry_str)
    if m:
        return m.group(1).strip(), m.group(2).strip()
    return None, None

def main():
    parser = argparse.ArgumentParser(description="DevOps/SRE Auto-Remediator")
    parser.add_argument("--report", default="sre_audit_report.json", help="Ruta al reporte JSON generado por audit_environment.py")
    parser.add_argument("--auto-approve", action="store_true", help="Aprobar automáticamente todas las remediaciones (Peligroso en Prod)")
    parser.add_argument("--dry-run", action="store_true", help="Mostrar comandos sin ejecutarlos")
    args = parser.parse_args()

    if not os.path.exists(args.report):
        print(f"{Colors.FAIL}[ERROR]{Colors.ENDC} No se encontró el archivo '{args.report}'.")
        print("Asegúrate de ejecutar primero: bash audit_environment.sh (o python3 audit_environment.py -o sre_audit_report -f all)")
        sys.exit(1)

    print(f"{Colors.OKGREEN}Cargando reporte de auditoría: {args.report}{Colors.ENDC}")
    try:
        with open(args.report, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"{Colors.FAIL}[ERROR] Fallo al leer el JSON:{Colors.ENDC} {e}")
        sys.exit(1)

    inventory = data.get("inventory", {})
    
    print_header("Módulo 1: Ejecución de Actionable Fixes")
    fixes_data = inventory.get("Remediación Automática (Actionable Fixes)", {}).get("Commands", [])
    if not fixes_data:
        print(f"{Colors.OKGREEN}No se encontraron Actionable Fixes pendientes.{Colors.ENDC}")
    else:
        for fix in fixes_data:
            concern = fix.get("concern", "General")
            target = fix.get("target", "")
            cmd = fix.get("command", "")
            note = fix.get("note", "")
            
            print(f"\n{Colors.BOLD}Problema:{Colors.ENDC} {concern} en {target}")
            if note:
                print(f"{Colors.OKCYAN}Nota:{Colors.ENDC} {note}")
            
            if prompt_user(f"¿Ejecutar: '{cmd}'?", args.auto_approve):
                run_cmd(cmd, args.dry_run)
            else:
                print(f"  {Colors.WARNING}Omitido.{Colors.ENDC}")

    print_header("Módulo 2: Limpieza de Recursos Huérfanos")
    orphans = inventory.get("Recursos Huérfanos", {})
    orphan_cms = orphans.get("OrphanConfigMaps", [])
    orphan_secs = orphans.get("OrphanSecrets", [])
    
    if not orphan_cms and not orphan_secs:
        print(f"{Colors.OKGREEN}No se encontraron recursos huérfanos (etcd limpio).{Colors.ENDC}")
    
    for cm_str in orphan_cms:
        name, ns = parse_ns_name(cm_str)
        if name and ns:
            cmd = f"kubectl delete configmap {name} -n {ns}"
            if prompt_user(f"¿Eliminar ConfigMap Huérfano '{name}' en '{ns}'?\nComando: {cmd}", args.auto_approve):
                run_cmd(cmd, args.dry_run)
            else:
                print(f"  {Colors.WARNING}Omitido.{Colors.ENDC}")

    for sec_str in orphan_secs:
        name, ns = parse_ns_name(sec_str)
        if name and ns:
            cmd = f"kubectl delete secret {name} -n {ns}"
            if prompt_user(f"¿Eliminar Secret Huérfano '{name}' en '{ns}'?\nComando: {cmd}", args.auto_approve):
                run_cmd(cmd, args.dry_run)
            else:
                print(f"  {Colors.WARNING}Omitido.{Colors.ENDC}")

    print_header("Módulo 3: Parcheo de Seguridad de Cargas de Trabajo (Pod Security)")
    # Buscar en findings "critical" y "warning" para Pod Security
    findings = data.get("findings", {})
    all_findings = findings.get("critical", []) + findings.get("warning", [])
    security_findings = [f for f in all_findings if f.get("category") == "Seguridad de Cargas de Trabajo (Pod Security)"]
    
    if not security_findings:
        print(f"{Colors.OKGREEN}No se encontraron problemas de Pod Security remediables.{Colors.ENDC}")
    else:
        for f in security_findings:
            desc = f.get("description", "")
            detail = f.get("detail", "")
            
            # Buscamos coincidencias tipo: 'container' en deployment 'name' (ns)
            matches = re.finditer(r"'([^']+)' en (\w+) '([^']+)' \(([^)]+)\)", detail)
            
            # Determinamos el tipo de parche
            patch_type = None
            op_value = ""
            if "PRIVILEGIADO" in desc:
                patch_type = "Privileged"
                op_value = '{"securityContext": {"privileged": false}}'
            elif "runAsNonRoot" in desc:
                patch_type = "RunAsNonRoot"
                op_value = '{"securityContext": {"runAsNonRoot": true}}'
                
            if patch_type:
                print(f"\n{Colors.BOLD}Resolviendo:{Colors.ENDC} {desc}")
                for m in matches:
                    c_name, w_kind, w_name, ns = m.groups()
                    # format: kubectl patch deployment name -n ns -p '{"spec":{"template":{"spec":{"containers":[{"name":"c_name", "securityContext":{...}}]}}}}'
                    # Esto asume que patching el spec reconstruye o actualiza el contenedor
                    patch_json = f'{{"spec":{{"template":{{"spec":{{"containers":[{{"name":"{c_name}", {op_value[1:]}]}}}}}}}}'
                    cmd = f"kubectl patch {w_kind} {w_name} -n {ns} -p '{patch_json}'"
                    
                    if prompt_user(f"¿Aplicar parche de seguridad ({patch_type}) a '{c_name}' en {w_kind} '{w_name}'?\nComando: {cmd}", args.auto_approve):
                        run_cmd(cmd, args.dry_run)
                    else:
                        print(f"  {Colors.WARNING}Omitido.{Colors.ENDC}")

    print(f"\n{Colors.BOLD}{Colors.OKGREEN}=== Remediación Finalizada ==={Colors.ENDC}")

if __name__ == "__main__":
    main()

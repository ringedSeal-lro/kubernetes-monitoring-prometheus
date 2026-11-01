
#!/usr/bin/env bash

set -Eeuo pipefail

METALLB_VERSION="${METALLB_VERSION:-0.15.3}"

METALLB_NAMESPACE="metallb-system"
NGINX_NAMESPACE="nginx-ingress"
MONITORING_NAMESPACE="monitoring"

NGINX_RELEASE="nginx-ingress"
PROMETHEUS_RELEASE="prometheus"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

IPPOOL_FILE="${SCRIPT_DIR}/IPPool.yaml"
PROMETHEUS_LB_FILE="${SCRIPT_DIR}/prometheus-lb.yaml"
GRAFANA_LB_FILE="${SCRIPT_DIR}/grafana-lb.yaml"
KUBEPROXY_BACKUP="${SCRIPT_DIR}/kube-proxy-backup.json"

METALLB_MANIFEST="https://raw.githubusercontent.com/metallb/metallb/v${METALLB_VERSION}/config/manifests/metallb-native.yaml"

CONFIRM=false
RESTORE_KUBEPROXY="${RESTORE_KUBEPROXY:-true}"

log() {
    printf '\n[INFO] %s\n' "$*"
}

warn() {
    printf '\n[WARN] %s\n' "$*" >&2
}

die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [--yes] [--help]

Options:
  --yes    Skip interactive confirmation.
  --help   Display this help message.

Environment variables:
  METALLB_VERSION       MetalLB version to remove (default: 0.15.3)
  RESTORE_KUBEPROXY     Restore saved kube-proxy configuration (default: true)
EOF
}

for arg in "$@"; do
    case "$arg" in
        --yes)  CONFIRM=true ;;
        --help) usage; exit 0 ;;
        *)      die "Unknown argument: $arg" ;;
    esac
done

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

uninstall_helm_release() {
    local release="$1"
    local namespace="$2"

    if helm status "$release" -n "$namespace" >/dev/null 2>&1; then
        log "Uninstalling Helm release '$release' from '$namespace'..."
        helm uninstall "$release" -n "$namespace" --wait
    else
        log "Helm release '$release' not found; skipping."
    fi
}

remove_manifest_if_present() {
    local file="$1"

    if [[ -f "$file" ]]; then
        kubectl delete -f "$file" --ignore-not-found=true
    else
        warn "Manifest not found: $file"
    fi
}

restore_kube_proxy() {
    [[ "$RESTORE_KUBEPROXY" == "true" ]] || {
        log "Skipping kube-proxy restoration."
        return
    }

    [[ -f "$KUBEPROXY_BACKUP" ]] || {
        log "No kube-proxy backup found; skipping restoration."
        return
    }

    require_command python3
    python3 -c 'import yaml' 2>/dev/null ||
        die "PyYAML is required to restore kube-proxy."

    log "Preparing to restore the original kube-proxy configuration..."

    local patch_file
    patch_file="$(mktemp)"

    python3 - "$KUBEPROXY_BACKUP" "$patch_file" <<'PY'
import json
import sys

backup_path, output_path = sys.argv[1:3]

with open(backup_path, encoding="utf-8") as f:
    obj = json.load(f)

original_config = obj.get("data", {}).get("config.conf")

if original_config is None:
    raise SystemExit(
        "The backup does not contain data.config.conf; "
        "restore the configuration manually."
    )

patch = {"data": {"config.conf": original_config}}

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(patch, f)
PY

    kubectl patch configmap kube-proxy \
        -n kube-system \
        --type merge \
        --patch-file "$patch_file"

    rm -f "$patch_file"

    log "Requesting kube-proxy pod recreation..."
    kubectl delete pods -n kube-system \
        -l k8s-app=kube-proxy \
        --ignore-not-found=true \
        --wait=false ||
        warn "Could not recreate kube-proxy pods automatically."

    log "Original kube-proxy configuration restored from backup."
    warn "The backup file has been preserved: $KUBEPROXY_BACKUP"
}

main() {
    require_command kubectl
    require_command helm

    kubectl cluster-info >/dev/null 2>&1 ||
        die "Cannot access the Kubernetes cluster. Check your kubeconfig."

    log "Current context: $(kubectl config current-context)"

    cat <<EOF

The following components will be removed:
  - Prometheus external LoadBalancer service
  - Grafana external LoadBalancer service
  - kube-prometheus-stack Helm release
  - NGINX Ingress Controller Helm release
  - MetalLB IPAddressPool and L2Advertisement
  - MetalLB installation

The monitoring and NGINX namespaces will not be deleted.

WARNING:
  Removing MetalLB can affect other LoadBalancer services.
  Review cluster dependencies before continuing.

EOF

    if [[ "$CONFIRM" != true ]]; then
        read -r -p "Continue with uninstallation? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || {
            log "Uninstallation cancelled."
            exit 0
        }
    fi

    # Remove only the external services defined by this project.
    log "Removing Prometheus and Grafana external services..."
    remove_manifest_if_present "$PROMETHEUS_LB_FILE"
    remove_manifest_if_present "$GRAFANA_LB_FILE"

    # Remove Helm releases.
    uninstall_helm_release \
        "$PROMETHEUS_RELEASE" \
        "$MONITORING_NAMESPACE"

    uninstall_helm_release \
        "$NGINX_RELEASE" \
        "$NGINX_NAMESPACE"

    # Remove MetalLB configuration before removing MetalLB.
    log "Removing the MetalLB IP pool configuration..."
    remove_manifest_if_present "$IPPOOL_FILE"

    # Restore kube-proxy if the installation script created a backup.
    restore_kube_proxy

    # Remove MetalLB only if its namespace exists.
    if kubectl get namespace "$METALLB_NAMESPACE" \
        >/dev/null 2>&1; then
        log "Removing MetalLB installation..."

        kubectl delete -f "$METALLB_MANIFEST" \
            --ignore-not-found=true \
            --wait=true
    else
        log "MetalLB namespace not found; skipping."
    fi

    log "Uninstallation steps completed."

    cat <<EOF

Review remaining resources:
  kubectl get pods,svc -n monitoring
  kubectl get pods,svc -n nginx-ingress
  kubectl get pods -n metallb-system

The namespaces and IPVS kernel modules were not automatically removed.
EOF
}

main "$@"


#!/usr/bin/env bash

set -Eeuo pipefail

METALLB_VERSION="${METALLB_VERSION:-0.15.3}"
NGINX_CHART_VERSION="${NGINX_CHART_VERSION:-2.5.1}"

NGINX_EXTERNAL_IP="${NGINX_EXTERNAL_IP:-192.168.1.240}"

METALLB_NAMESPACE="metallb-system"
NGINX_NAMESPACE="nginx-ingress"
MONITORING_NAMESPACE="monitoring"

NGINX_RELEASE="nginx-ingress"
PROMETHEUS_RELEASE="prometheus"

KUBEPROXY_CONFIGURE="${KUBEPROXY_CONFIGURE:-false}"
CONFIGURE_LOCAL_NODE="${CONFIGURE_LOCAL_NODE:-false}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

IPPOOL_FILE="${SCRIPT_DIR}/IPPool.yaml"
PROMETHEUS_LB_FILE="${SCRIPT_DIR}/prometheus-lb.yaml"
GRAFANA_LB_FILE="${SCRIPT_DIR}/grafana-lb.yaml"

KUBEPROXY_BACKUP="${SCRIPT_DIR}/kube-proxy-backup.json"

METALLB_MANIFEST="https://raw.githubusercontent.com/metallb/metallb/v${METALLB_VERSION}/config/manifests/metallb-native.yaml"

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

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

check_prerequisites() {
    local file

    for cmd in kubectl helm curl; do
        require_command "$cmd"
    done

    for file in \
        "$IPPOOL_FILE" \
        "$PROMETHEUS_LB_FILE" \
        "$GRAFANA_LB_FILE"; do
        [[ -f "$file" ]] || die "Required file not found: $file"
    done

    if [[ "$KUBEPROXY_CONFIGURE" == "true" ]]; then
        require_command python3
        python3 -c 'import yaml' 2>/dev/null ||
            die "PyYAML is required. Install it before configuring kube-proxy."
    fi

    kubectl cluster-info >/dev/null 2>&1 ||
        die "Cannot access the Kubernetes cluster. Check your kubeconfig."

    log "Current context: $(kubectl config current-context)"
    kubectl get nodes
}

configure_local_node() {
    [[ "$CONFIGURE_LOCAL_NODE" == "true" ]] || {
        log "Skipping local IPVS kernel module configuration."
        return
    }

    [[ "$(uname -s)" == "Linux" ]] ||
        die "CONFIGURE_LOCAL_NODE=true requires Linux."

    require_command sudo

    log "Loading IPVS modules on the local machine..."

    local modules=(
        ip_vs
        ip_vs_rr
        ip_vs_wrr
        ip_vs_sh
        nf_conntrack
    )

    local module
    for module in "${modules[@]}"; do
        sudo modprobe "$module"
    done

    printf '%s\n' "${modules[@]}" |
        sudo tee /etc/modules-load.d/ipvs.conf >/dev/null

    log "IPVS modules configured on this machine only."
}

configure_kube_proxy() {
    [[ "$KUBEPROXY_CONFIGURE" == "true" ]] || {
        log "Skipping kube-proxy configuration."
        return
    }

    log "Backing up the kube-proxy ConfigMap..."

    if [[ ! -f "$KUBEPROXY_BACKUP" ]]; then
        kubectl get configmap kube-proxy \
            -n kube-system -o json > "$KUBEPROXY_BACKUP"

        warn "Backup saved to $KUBEPROXY_BACKUP"
        warn "Do not commit this backup to a public repository."
    else
        log "Existing kube-proxy backup will be preserved."
    fi

    local patched_file
    patched_file="$(mktemp)"

    python3 - "$KUBEPROXY_BACKUP" "$patched_file" <<'PY'
import json
import sys
import yaml

backup_path, output_path = sys.argv[1:3]

with open(backup_path, encoding="utf-8") as f:
    obj = json.load(f)

data = obj.setdefault("data", {})
config_key = "config.conf"

if config_key not in data:
    raise SystemExit(
        "ConfigMap does not contain data.config.conf; "
        "inspect the kube-proxy configuration manually."
    )

config = yaml.safe_load(data[config_key]) or {}
config["mode"] = "ipvs"
config.setdefault("ipvs", {})["strictARP"] = True

data[config_key] = yaml.safe_dump(config, sort_keys=False)

metadata = obj.get("metadata", {})
for key in (
    "resourceVersion",
    "uid",
    "creationTimestamp",
    "managedFields",
    "generation",
):
    metadata.pop(key, None)

obj.pop("status", None)

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(obj, f)
PY

    log "Applying kube-proxy configuration..."
    kubectl apply -f "$patched_file"
    rm -f "$patched_file"

    log "Requesting kube-proxy pod recreation..."
    kubectl delete pods -n kube-system \
        -l k8s-app=kube-proxy \
        --ignore-not-found=true \
        --wait=false || warn "Could not recreate kube-proxy pods automatically."

    warn "Ensure IPVS modules are available on every relevant Kubernetes node."
}

install_metallb() {
    log "Installing MetalLB ${METALLB_VERSION}..."

    kubectl apply -f "$METALLB_MANIFEST"

    kubectl wait \
        --for=condition=Established \
        crd/ipaddresspools.metallb.io \
        --timeout=180s

    kubectl rollout status deployment/controller \
        -n "$METALLB_NAMESPACE" \
        --timeout=300s

    kubectl rollout status daemonset/speaker \
        -n "$METALLB_NAMESPACE" \
        --timeout=300s

    log "Applying MetalLB IP pool..."
    kubectl apply -f "$IPPOOL_FILE"

    kubectl get ipaddresspools,l2advertisements \
        -n "$METALLB_NAMESPACE"
}

install_nginx() {
    log "Installing NGINX Ingress Controller..."

    helm upgrade --install "$NGINX_RELEASE" \
        oci://ghcr.io/nginx/charts/nginx-ingress \
        --version "$NGINX_CHART_VERSION" \
        --namespace "$NGINX_NAMESPACE" \
        --create-namespace \
        --set controller.service.type=NodePort \
        --set controller.replicaCount=1 \
        --wait \
        --timeout 10m

    local service="${NGINX_RELEASE}-controller"

    kubectl get svc "$service" -n "$NGINX_NAMESPACE" \
        >/dev/null 2>&1 ||
        die "Expected NGINX service '$service' was not found."

    log "Configuring NGINX service as LoadBalancer at ${NGINX_EXTERNAL_IP}..."

    kubectl patch svc "$service" \
        -n "$NGINX_NAMESPACE" \
        --type merge \
        -p "{\"spec\":{\"type\":\"LoadBalancer\",\"loadBalancerIP\":\"${NGINX_EXTERNAL_IP}\"}}"

    kubectl get svc -n "$NGINX_NAMESPACE"
}

install_prometheus_stack() {
    log "Installing kube-prometheus-stack..."

    helm upgrade --install "$PROMETHEUS_RELEASE" \
        oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
        --namespace "$MONITORING_NAMESPACE" \
        --create-namespace \
        --wait \
        --timeout 15m

    log "Applying Prometheus external service..."
    kubectl apply -f "$PROMETHEUS_LB_FILE"

    log "Applying Grafana external service..."
    kubectl apply -f "$GRAFANA_LB_FILE"

    kubectl get svc -n "$MONITORING_NAMESPACE"
}

validate_setup() {
    log "Monitoring pods:"
    kubectl get pods -n "$MONITORING_NAMESPACE"

    log "MetalLB resources:"
    kubectl get ipaddresspools,l2advertisements \
        -n "$METALLB_NAMESPACE"

    log "NGINX service:"
    kubectl get svc -n "$NGINX_NAMESPACE"

    log "Prometheus and Grafana services:"
    kubectl get svc prometheus-lb grafana-lb \
        -n "$MONITORING_NAMESPACE"

    log "Checking service endpoints..."
    kubectl get endpoints prometheus-lb grafana-lb \
        -n "$MONITORING_NAMESPACE" || true

    cat <<EOF

Installation steps completed.

Expected example endpoints:
  NGINX:      ${NGINX_EXTERNAL_IP}
  Prometheus: http://192.168.1.242:9090
  Grafana:    http://192.168.1.242:8080

Verify the assigned external IPs and service endpoints before use.
EOF
}

main() {
    check_prerequisites
    configure_local_node
    configure_kube_proxy
    install_metallb
    install_nginx
    install_prometheus_stack
    validate_setup
}

main "$@"

#!/bin/bash
set -euo pipefail

PR_NUMBER="${PR_NUM:-6}"
echo "Deploying ephemeral environment for PR #${PR_NUMBER}..."

VCLUSTER_NAME="pr-${PR_NUMBER}"
VCLUSTER_NAMESPACE="vcluster-pr-${PR_NUMBER}"
APP_NAMESPACE="node-ns"

# Save host cluster KUBECONFIG reference
HOST_KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG="$HOST_KUBECONFIG"

# 1. Create or upgrade vcluster on HOST cluster
vcluster create "$VCLUSTER_NAME" -n "${VCLUSTER_NAMESPACE}" -f vcluster.yaml --upgrade --connect=false
kubectl wait --for=condition=ready pod -l app=vcluster,release=$VCLUSTER_NAME -n "$VCLUSTER_NAMESPACE" --timeout=120s
echo "${VCLUSTER_NAME} vcluster created successfully."

# ------------------------------------------------------------------
# STEP A: Extract Virtual Cluster Kubeconfig Secret directly
# ------------------------------------------------------------------
# ------------------------------------------------------------------
# STEP A: Extract Virtual Cluster Kubeconfig Secret & Auto-Detect Mode
# ------------------------------------------------------------------
echo "Extracting virtual cluster access configuration..."

VC_KUBECONFIG="/tmp/vc-kubeconfig-${PR_NUMBER}.yaml"

# Auto-detect if running inside a cluster (like a GitHub runner pod) or locally
if [ -n "${KUBERNETES_SERVICE_HOST:-}" ] || [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    IS_IN_CLUSTER="true"
else
    IS_IN_CLUSTER="${IN_CLUSTER:-false}"
fi

for i in {1..15}; do
    if kubectl get secret "vc-${VCLUSTER_NAME}" -n "$VCLUSTER_NAMESPACE" >/dev/null 2>&1; then
        kubectl get secret "vc-${VCLUSTER_NAME}" -n "$VCLUSTER_NAMESPACE" -o jsonpath="{.data.config}" | base64 --decode > "$VC_KUBECONFIG"
        
        if [ "$IS_IN_CLUSTER" = "true" ]; then
            # CI / In-Cluster Execution: Use internal service name matching cert SAN
            INTERNAL_VC_URL="https://${VCLUSTER_NAME}.${VCLUSTER_NAMESPACE}:443"
            sed -i -E "s|server: https://[^[:space:]]+|server: ${INTERNAL_VC_URL}|g" "$VC_KUBECONFIG"
            
            # Force insecure-skip-tls-verify directly into the kubeconfig YAML
            if grep -q "insecure-skip-tls-verify" "$VC_KUBECONFIG"; then
                sed -i 's/insecure-skip-tls-verify: false/insecure-skip-tls-verify: true/g' "$VC_KUBECONFIG"
            else
                sed -i '/server: .*/a \    insecure-skip-tls-verify: true' "$VC_KUBECONFIG"
            fi
            
            echo "Running in-cluster (CI mode) -> targeting ${INTERNAL_VC_URL}"
        else
            # Local Laptop Execution: Start background port-forward
            echo "Running locally -> setting up background port-forward..."
            pkill -f "port-forward -n ${VCLUSTER_NAMESPACE} svc/${VCLUSTER_NAME}" || true
            kubectl port-forward -n "$VCLUSTER_NAMESPACE" "svc/${VCLUSTER_NAME}" 8443:443 > /dev/null 2>&1 &
            PF_PID=$!
            trap "kill $PF_PID 2>/dev/null || true" EXIT
            sleep 2
            
            LOCAL_VC_URL="https://127.0.0.1:8443"
            sed -i -E "s|server: https://[^[:space:]]+|server: ${LOCAL_VC_URL}|g" "$VC_KUBECONFIG"
            kubectl config set-cluster default --insecure-skip-tls-verify=true --kubeconfig="$VC_KUBECONFIG" >/dev/null 2>&1 || true
        fi
        break
    fi
    sleep 2
done
# ------------------------------------------------------------------
# STEP B: Deploy Workload INSIDE Virtual Cluster
# ------------------------------------------------------------------
echo "Deploying workloads inside vcluster..."

# Create namespace inside vcluster (disable validation to prevent openapi timeout lookup issues)
kubectl --kubeconfig="$VC_KUBECONFIG" create namespace "$APP_NAMESPACE" --dry-run=client -o yaml | kubectl --kubeconfig="$VC_KUBECONFIG" apply --validate=false -f -

# Apply deployment and service inside vcluster
kubectl --kubeconfig="$VC_KUBECONFIG" apply --validate=false -f deployment.yaml -n "$APP_NAMESPACE"
kubectl --kubeconfig="$VC_KUBECONFIG" apply --validate=false -f service.yaml -n "$APP_NAMESPACE"

# Wait for workload pods to be created and ready inside vcluster
echo "Waiting for workload pods to start..."
for i in {1..20}; do
    if kubectl --kubeconfig="$VC_KUBECONFIG" get pods -n "$APP_NAMESPACE" -l app=node-test-app --no-headers 2>/dev/null | grep -q .; then
        break
    fi
    sleep 2
done

kubectl --kubeconfig="$VC_KUBECONFIG" wait --for=condition=ready pod -l app=node-test-app -n "$APP_NAMESPACE" --timeout=120s
echo "Workload pods are ready inside vcluster."
# ------------------------------------------------------------------
# STEP C: Apply HTTPRoute on HOST Cluster
# ------------------------------------------------------------------
# Switch back to HOST cluster context
export KUBECONFIG="$HOST_KUBECONFIG"

echo "Fetching synced service name from host namespace ${VCLUSTER_NAMESPACE}..."
SYNCED_SVC=""
for i in {1..15}; do
    SYNCED_SVC=$(kubectl get svc -n "$VCLUSTER_NAMESPACE" --no-headers -o custom-columns=":metadata.name" | grep "node-test-app-service" | head -n 1 || true)
    if [ -n "$SYNCED_SVC" ]; then
        echo "Found synced host service: ${SYNCED_SVC}"
        break
    fi
    echo "Waiting for service sync... (${i}/15)"
    sleep 2
done

if [ -z "$SYNCED_SVC" ]; then
    echo "ERROR: Synced service not found in host namespace ${VCLUSTER_NAMESPACE}!"
    exit 1
fi

# Prepare host HTTPRoute manifest with dynamic backend service and host domain
cp httproute.yaml "pr-${PR_NUMBER}-httproute.yaml"
sed -i "s|- pr-.*\.local|- pr-${PR_NUMBER}.local|" "pr-${PR_NUMBER}-httproute.yaml"
sed -i "s|name: node-test-app-service|name: ${SYNCED_SVC}|" "pr-${PR_NUMBER}-httproute.yaml"

# Apply HTTPRoute to host namespace where vcluster lives
kubectl apply -f "pr-${PR_NUMBER}-httproute.yaml" -n "$VCLUSTER_NAMESPACE"
rm -f "pr-${PR_NUMBER}-httproute.yaml"

echo "pr-${PR_NUMBER} deployment completed successfully!"
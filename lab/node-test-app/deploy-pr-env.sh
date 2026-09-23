#!/bin/bash
set -euo pipefail

PR_NUMBER=6
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
# STEP A: Deploy Workload INSIDE Virtual Cluster via vcluster CLI
# ------------------------------------------------------------------
echo "Deploying workloads inside vcluster..."

# Create namespace inside vcluster using a temporary manifest file
cat <<EOF > /tmp/ns-${PR_NUMBER}.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ${APP_NAMESPACE}
EOF

vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" --silent -- kubectl apply -f /tmp/ns-${PR_NUMBER}.yaml
rm -f /tmp/ns-${PR_NUMBER}.yaml

vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" --silent -- kubectl apply -f deployment.yaml -n "$APP_NAMESPACE"
vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" --silent -- kubectl apply -f service.yaml -n "$APP_NAMESPACE"

vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" --silent -- kubectl wait --for=condition=ready pod -l app=node-test-app -n "$APP_NAMESPACE" --timeout=120s
echo "Workload pods are ready inside vcluster."

# ------------------------------------------------------------------
# STEP B: Apply HTTPRoute on HOST Cluster
# ------------------------------------------------------------------
# Dynamically fetch synced service name from host namespace
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
echo "pr-${PR_NUMBER} HTTPRoute applied to host namespace ${VCLUSTER_NAMESPACE}."

echo "pr-${PR_NUMBER} deployment completed successfully!"
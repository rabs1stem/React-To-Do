#!/bin/bash

set -Eeuo pipefail

NAMESPACE="reac"
INGRESS_LOCAL_PORT="${INGRESS_LOCAL_PORT:-8080}"

METRICS_SERVER_VERSION="v0.7.1"
INGRESS_NGINX_VERSION="controller-v1.12.1"
SEALED_SECRETS_VERSION="v0.28.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

cleanup() {
  echo "=== Cleanup completed ==="
}

trap cleanup EXIT

echo "=== Check kubectl ==="

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl not installed"
  exit 1
}

echo "=== Check helm ==="

command -v helm >/dev/null 2>&1 || {
  echo "helm not installed"
  exit 1
}

echo "=== Check kubeseal ==="

command -v kubeseal >/dev/null 2>&1 || {
  echo "kubeseal not installed"
  exit 1
}

echo "=== Current kubectl context ==="

kubectl config current-context

echo "=== Add secret.yaml to .gitignore ==="

if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.gitignore" ]; then
  grep -qxF "k8s/secret.yaml" "$REPO_ROOT/.gitignore" || \
    echo "k8s/secret.yaml" >> "$REPO_ROOT/.gitignore"
else
  echo "Skip .gitignore update: git repo root not found"
fi

echo "=== Create namespace ==="

kubectl apply -f namespace.yaml

echo "=== Wait namespace active ==="

MAX_WAIT_SECONDS=120
ELAPSED_SECONDS=0
SLEEP_SECONDS=2

until [ "$(kubectl get ns "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Active" ]; do
  echo "Waiting for namespace $NAMESPACE to become Active..."

  sleep "$SLEEP_SECONDS"

  ELAPSED_SECONDS=$((ELAPSED_SECONDS + SLEEP_SECONDS))

  if [ "$ELAPSED_SECONDS" -ge "$MAX_WAIT_SECONDS" ]; then
    echo "ERROR: Namespace $NAMESPACE did not become Active"
    exit 1
  fi
done

echo "=== Install metrics-server ==="

kubectl apply -f \
  "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

echo "=== Patch metrics-server ==="

kubectl patch deployment metrics-server \
  -n kube-system \
  --type='json' \
  -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/args/-",
      "value": "--kubelet-insecure-tls"
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/args/-",
      "value": "--kubelet-preferred-address-types=InternalIP"
    }
  ]' || true

echo "=== Wait metrics-server rollout ==="

kubectl rollout status deployment/metrics-server \
  -n kube-system \
  --timeout=300s

echo "=== Wait Metrics API ==="

MAX_METRICS_WAIT=60
METRICS_WAITED=0

until kubectl top nodes >/dev/null 2>&1; do
  echo "Waiting for Metrics API..."

  sleep 2

  METRICS_WAITED=$((METRICS_WAITED + 2))

  if [ "$METRICS_WAITED" -ge "$MAX_METRICS_WAIT" ]; then
    echo "ERROR: Metrics API unavailable"

    echo "=== API Services ==="
    kubectl get apiservices | grep metrics || true

    echo "=== metrics-server logs ==="
    kubectl logs -n kube-system deployment/metrics-server || true

    exit 1
  fi
done

echo "Metrics API working"

echo "=== Check ingress-nginx ==="

if ! kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
  echo "Installing ingress-nginx..."

  kubectl apply -f \
    "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml"
else
  echo "ingress-nginx already installed"
fi

echo "=== Wait ingress-nginx controller ==="

kubectl rollout status deployment/ingress-nginx-controller \
  -n ingress-nginx \
  --timeout=300s

echo "=== Check sealed-secrets controller ==="

if ! kubectl get deployment sealed-secrets-controller -n kube-system >/dev/null 2>&1; then
  echo "Installing sealed-secrets controller..."

  kubectl apply -f \
    "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml"
else
  echo "sealed-secrets controller already installed"
fi

echo "=== Wait sealed-secrets controller ==="

kubectl rollout status deployment/sealed-secrets-controller \
  -n kube-system \
  --timeout=300s

echo "=== Check secret.yaml ==="

if [ ! -f secret.yaml ]; then
  echo "secret.yaml not found"
  exit 1
fi

echo "=== Generate SealedSecret ==="

kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  --format yaml \
  < secret.yaml \
  > backend-chart/templates/sealedsecret.yaml

echo "=== Deploy postgres ==="

helm upgrade --install postgres ./postgres-chart \
  -n "$NAMESPACE" \
  --wait \
  --timeout 5m

echo "=== Deploy backend ==="

helm upgrade --install backend ./backend-chart \
  -n "$NAMESPACE" \
  --wait \
  --timeout 5m

echo "=== Deploy frontend ==="

helm upgrade --install frontend ./frontend-chart \
  -n "$NAMESPACE" \
  --wait \
  --timeout 5m

echo "=== Wait backend rollout ==="

kubectl rollout status deployment/backend \
  -n "$NAMESPACE" \
  --timeout=300s

echo "=== Wait frontend rollout ==="

kubectl rollout status deployment/frontend \
  -n "$NAMESPACE" \
  --timeout=300s

echo "=== Wait postgres rollout ==="

kubectl rollout status statefulset/postgres \
  -n "$NAMESPACE" \
  --timeout=300s

echo "=== HPA ==="

kubectl get hpa -n "$NAMESPACE"

echo "=== Pods ==="

kubectl get pods -n "$NAMESPACE"

echo "=== Services ==="

kubectl get svc -n "$NAMESPACE"

echo "=== Ingress ==="

kubectl get ingress -n "$NAMESPACE"

echo "=== Metrics ==="

kubectl top nodes || true
kubectl top pods -n "$NAMESPACE" || true

echo "=== Restart ingress port-forward ==="

pkill -f "kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller ${INGRESS_LOCAL_PORT}:80" >/dev/null 2>&1 || true

nohup kubectl port-forward \
  -n ingress-nginx \
  svc/ingress-nginx-controller \
  ${INGRESS_LOCAL_PORT}:80 \
  >/tmp/reac-ingress-port-forward.log 2>&1 &

sleep 3

if pgrep -f "kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller ${INGRESS_LOCAL_PORT}:80" >/dev/null 2>&1; then
  echo "=== Port-forward started ==="
  echo "Application: http://localhost:${INGRESS_LOCAL_PORT}"
  echo "Logs: /tmp/reac-ingress-port-forward.log"
else
  echo "WARNING: port-forward failed to start"
  echo "Run manually:"
  echo "kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller ${INGRESS_LOCAL_PORT}:80"
fi

echo "=== Deploy completed successfully ==="
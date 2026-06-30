#!/usr/bin/env bash
# Opens SSM API tunnel + kubectl port-forwards for all DevOps cluster UIs.
# No /etc/hosts changes needed — services are on plain localhost ports.
#
# Usage: ./scripts/tunnel.sh [dev|prod]
#
#   http://localhost:8080  ArgoCD
#   http://localhost:8081  Woodpecker
#   http://localhost:8082  Grafana

set -euo pipefail

ENV=${1:-dev}
REGION="eu-central-1"
PROFILE="tf-dev"
KUBECONFIG_PATH="$HOME/.kube/devops-cluster-$ENV"
export KUBECONFIG="$KUBECONFIG_PATH"

echo "==> Finding DevOps cluster server node ($ENV)..."
SERVER_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Role,Values=k3s-server" \
    "Name=tag:Environment,Values=$ENV" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text \
  --profile "$PROFILE" \
  --region "$REGION")

echo "    Server: $SERVER_ID"
echo "==> Starting K3s API tunnel (port 6443)..."

aws ssm start-session \
  --target "$SERVER_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}' \
  --profile "$PROFILE" \
  --region "$REGION" &
TUNNEL_PID=$!

trap "kill $TUNNEL_PID 2>/dev/null; kill 0" EXIT INT TERM
sleep 4

echo "==> Starting port-forwards..."
kubectl port-forward -n argocd      svc/argocd-server                    8080:80  &
kubectl port-forward -n woodpecker  svc/woodpecker-server                8081:80  &
kubectl port-forward -n monitoring  svc/kube-prometheus-stack-grafana    8082:80  &

echo ""
echo "    http://localhost:8080  ArgoCD"
echo "    http://localhost:8081  Woodpecker"
echo "    http://localhost:8082  Grafana"
echo ""
echo "    Ctrl+C to stop"

wait

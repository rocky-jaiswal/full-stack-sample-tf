#!/usr/bin/env bash
# Opens an SSM port-forward to the App cluster's K3s API (port 6443).
# Keep this running in a separate terminal for kubectl/helm commands against
# the App cluster, or while registering it with ArgoCD.
#
# Usage: ./scripts/api-tunnel-app.sh [dev|prod]

set -euo pipefail

ENV=${1:-dev}
REGION="eu-central-1"
PROFILE="tf-dev"

echo "==> Finding App cluster server node ($ENV)..."
SERVER_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Role,Values=k3s-server" \
    "Name=tag:Cluster,Values=app" \
    "Name=tag:Environment,Values=$ENV" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text \
  --profile "$PROFILE" \
  --region "$REGION")

echo "    K3s API available at localhost:6443 via $SERVER_ID"
echo "    Ctrl+C to stop"
echo ""

aws ssm start-session \
  --target "$SERVER_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}' \
  --profile "$PROFILE" \
  --region "$REGION"

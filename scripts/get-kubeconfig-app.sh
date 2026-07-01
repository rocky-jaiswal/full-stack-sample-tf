#!/usr/bin/env bash
# Fetches the K3s kubeconfig from the App cluster server node via SSM.
# Run once after the cluster is provisioned (or after cluster recreation).
#
# Usage: ./scripts/get-kubeconfig-app.sh [dev|prod]

set -euo pipefail

ENV=${1:-dev}
REGION="eu-central-1"
PROFILE="tf-dev"
KUBECONFIG_PATH="$HOME/.kube/app-cluster-$ENV"

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
echo "    Server: $SERVER_ID"

echo "==> Fetching kubeconfig..."
COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$SERVER_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["cat /etc/rancher/k3s/k3s.yaml"]' \
  --query "Command.CommandId" \
  --output text \
  --profile "$PROFILE" \
  --region "$REGION")

aws ssm wait command-executed \
  --command-id "$COMMAND_ID" \
  --instance-id "$SERVER_ID" \
  --profile "$PROFILE" \
  --region "$REGION"

mkdir -p "$HOME/.kube"
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$SERVER_ID" \
  --query "StandardOutputContent" \
  --output text \
  --profile "$PROFILE" \
  --region "$REGION" > "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

echo "==> Done. Kubeconfig saved to $KUBECONFIG_PATH"
echo ""
echo "Next: ./scripts/api-tunnel-app.sh $ENV   # K3s API tunnel, then KUBECONFIG=$KUBECONFIG_PATH kubectl ..."

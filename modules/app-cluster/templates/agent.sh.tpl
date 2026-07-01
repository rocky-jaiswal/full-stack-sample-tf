#!/bin/bash
set -euo pipefail

until curl -sk https://${server_ip}:6443/ping > /dev/null 2>&1; do
  echo "Waiting for K3s server..."
  sleep 10
done

curl -sfL https://get.k3s.io | \
  K3S_TOKEN="${k3s_token}" \
  K3S_URL="https://${server_ip}:6443" \
  sh -s - agent

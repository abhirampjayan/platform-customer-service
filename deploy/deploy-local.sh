#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
SSH_KEY="${SSH_KEY:-$HOME/Downloads/platform-service.pem}"
PUBLIC_IP="${PUBLIC_IP:-}"
IMAGE_NAME="${IMAGE_NAME:-timeout-service:local}"

if [[ -z "$PUBLIC_IP" && -d "$ROOT_DIR/deploy/terraform" ]]; then
  PUBLIC_IP="$(terraform -chdir="$ROOT_DIR/deploy/terraform" output -raw public_ip 2>/dev/null || true)"
fi

if [[ -z "$PUBLIC_IP" ]]; then
  printf 'PUBLIC_IP is required. Export it or apply the Terraform deployment first.\n' >&2
  exit 1
fi

if [[ ! -r "$SSH_KEY" ]]; then
  printf 'SSH key is not readable: %s\n' "$SSH_KEY" >&2
  exit 1
fi

if [[ -z "${CHAOS_TOKEN:-}" ]]; then
  CHAOS_TOKEN="$(openssl rand -hex 24)"
  printf 'Generated CHAOS_TOKEN. Store it securely before using /admin/chaos.\n'
fi

if [[ ${#CHAOS_TOKEN} -lt 32 ]]; then
  printf 'CHAOS_TOKEN must be at least 32 characters.\n' >&2
  exit 1
fi

SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "ec2-user@$PUBLIC_IP")

printf 'Checking SSH access to %s...\n' "$PUBLIC_IP"
"${SSH[@]}" 'echo connected >/dev/null'

printf 'Building %s for linux/arm64...\n' "$IMAGE_NAME"
docker buildx build --load --platform linux/arm64 --tag "$IMAGE_NAME" "$ROOT_DIR"

printf 'Transferring image to the instance...\n'
docker save "$IMAGE_NAME" | gzip -c | "${SSH[@]}" 'gzip -d | sudo docker load'

TOKEN_B64="$(printf %s "$CHAOS_TOKEN" | base64)"
printf 'Starting the container...\n'
"${SSH[@]}" "TOKEN_B64='$TOKEN_B64' AWS_REGION='$AWS_REGION' IMAGE_NAME='$IMAGE_NAME' bash -s" <<'REMOTE'
set -euo pipefail
CHAOS_TOKEN="$(printf %s "$TOKEN_B64" | base64 --decode)"

sudo docker rm -f timeout-service >/dev/null 2>&1 || true
sudo docker run -d \
  --name timeout-service \
  --restart unless-stopped \
  -p 80:8080 \
  --log-driver awslogs \
  --log-opt "awslogs-region=$AWS_REGION" \
  --log-opt awslogs-group=/sentinel-sample/timeout-service \
  --log-opt awslogs-stream=timeout-service \
  -e CHAOS_TOKEN="$CHAOS_TOKEN" \
  "$IMAGE_NAME" >/dev/null

sleep 2
sudo docker ps --filter name=timeout-service --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
curl --fail --silent http://127.0.0.1/healthz >/dev/null
REMOTE

printf 'Deployment succeeded. Health check: http://%s/healthz\n' "$PUBLIC_IP"
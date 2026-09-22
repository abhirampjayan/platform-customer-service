#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/abhirampjayan/timeout-service.git}"
APP_DIR="${APP_DIR:-/opt/timeout-service}"
IMAGE_NAME="${IMAGE_NAME:-timeout-service:local}"
PORT="${PORT:-80}"
HOST_PORT="${HOST_PORT:-8080}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LOG_GROUP="${LOG_GROUP:-/sentinel-sample/timeout-service}"

if [[ -z "${CHAOS_TOKEN:-}" ]]; then
  CHAOS_TOKEN="$(openssl rand -hex 24)"
  printf 'Generated CHAOS_TOKEN=%s\n' "$CHAOS_TOKEN"
fi

if [[ ${#CHAOS_TOKEN} -lt 32 ]]; then
  printf 'CHAOS_TOKEN must be at least 32 characters.\n' >&2
  exit 1
fi

sudo install -d -o ec2-user -g ec2-user "$APP_DIR"

if [[ ! -d "$APP_DIR/.git" ]]; then
  sudo git clone "$REPO_URL" "$APP_DIR"
fi

cd "$APP_DIR"

sudo git pull --ff-only origin "$(git branch --show-current || echo main)" || true

sudo docker build -t "$IMAGE_NAME" .

sudo docker rm -f timeout-service >/dev/null 2>&1 || true

sudo docker run -d \
  --name timeout-service \
  --restart unless-stopped \
  -p "$PORT:$HOST_PORT" \
  --log-driver awslogs \
  --log-opt "awslogs-region=$AWS_REGION" \
  --log-opt "awslogs-group=$LOG_GROUP" \
  --log-opt awslogs-stream=timeout-service \
  -e CHAOS_TOKEN="$CHAOS_TOKEN" \
  -e PORT="$HOST_PORT" \
  -e HOST="0.0.0.0" \
  -e NODE_ENV="production" \
  "$IMAGE_NAME"

sleep 2
sudo docker ps --filter name=timeout-service --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
curl --fail --silent http://127.0.0.1/healthz

printf '\nService is running at http://127.0.0.1:%s\n' "$PORT"
printf 'CHAOS_TOKEN=%s\n' "$CHAOS_TOKEN"

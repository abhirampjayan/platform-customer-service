#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="${REPO_URL:-https://github.com/abhirampjayan/platform-customer-service.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SSH_KEY="${SSH_KEY:-$HOME/Downloads/platform-service.pem}"
PUBLIC_IP="${PUBLIC_IP:-}"
IMAGE_NAME="${IMAGE_NAME:-timeout-service:local}"
PLATFORM="${PLATFORM:-linux/arm64}"
LOG_GROUP="${LOG_GROUP:-/sentinel-sample/timeout-service}"
# PORT is the public port; HOST_PORT is the port inside the container.
PORT="${PORT:-80}"
HOST_PORT="${HOST_PORT:-8080}"

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
  printf 'Export CHAOS_TOKEN (at least 32 characters) before deployment; keep it securely for /admin/chaos.\n' >&2
  exit 1
fi

if [[ ${#CHAOS_TOKEN} -lt 32 ]]; then
  printf 'CHAOS_TOKEN must be at least 32 characters.\n' >&2
  exit 1
fi

SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "ec2-user@$PUBLIC_IP")

printf 'Checking SSH access to %s...\n' "$PUBLIC_IP"
"${SSH[@]}" 'echo connected >/dev/null'

docker info >/dev/null
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf -- "$BUILD_DIR"' EXIT

printf 'Cloning a fresh copy of %s (branch %s)...\n' "$REPO_URL" "$REPO_BRANCH"
git clone --depth 1 --single-branch --branch "$REPO_BRANCH" -- "$REPO_URL" "$BUILD_DIR/source"

printf 'Building %s from scratch for %s...\n' "$IMAGE_NAME" "$PLATFORM"
docker buildx build --load --pull --no-cache --platform "$PLATFORM" --tag "$IMAGE_NAME" "$BUILD_DIR/source"

printf 'Transferring image to the instance...\n'
docker save "$IMAGE_NAME" | gzip -c | "${SSH[@]}" 'gzip -d | sudo docker load'

TOKEN_B64="$(printf %s "$CHAOS_TOKEN" | base64 | tr -d '\r\n')"
printf -v REMOTE_COMMAND '%q ' env "TOKEN_B64=$TOKEN_B64" "AWS_REGION=$AWS_REGION" \
  "IMAGE_NAME=$IMAGE_NAME" "LOG_GROUP=$LOG_GROUP" "PORT=$PORT" "HOST_PORT=$HOST_PORT" bash -s
printf 'Starting the container...\n'
"${SSH[@]}" "$REMOTE_COMMAND" <<'REMOTE'
set -euo pipefail
CHAOS_TOKEN="$(printf %s "$TOKEN_B64" | base64 --decode)"

# The image is already built and loaded. Replace only the service container.
EXISTING_CONTAINER="$(sudo docker container ls -aq --filter 'name=^/timeout-service$')"
if [[ -n "$EXISTING_CONTAINER" ]]; then
  sudo docker rm -f "$EXISTING_CONTAINER" >/dev/null
fi
export CHAOS_TOKEN
sudo --preserve-env=CHAOS_TOKEN docker run -d \
  --name timeout-service \
  --restart unless-stopped \
  -p "$PORT:$HOST_PORT" \
  --log-driver awslogs \
  --log-opt "awslogs-region=$AWS_REGION" \
  --log-opt "awslogs-group=$LOG_GROUP" \
  --log-opt awslogs-stream=timeout-service \
  -e CHAOS_TOKEN \
  -e PORT="$HOST_PORT" \
  -e HOST=0.0.0.0 \
  -e NODE_ENV=production \
  "$IMAGE_NAME" >/dev/null

sudo docker ps --filter name=timeout-service --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
curl --fail --silent --show-error --retry 20 --retry-connrefused \
  --retry-delay 2 --retry-max-time 90 --max-time 5 "http://127.0.0.1:$PORT/healthz" >/dev/null
REMOTE

printf 'Deployment succeeded. Public health check (allowed networks only): http://%s.sslip.io:%s/healthz\n' "$PUBLIC_IP" "$PORT"
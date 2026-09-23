#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/abhirampjayan/platform-customer-service.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/platform-customer-service}"
IMAGE_NAME="${IMAGE_NAME:-timeout-service:local}"
# PORT is the public port; HOST_PORT is the port inside the container.
PORT="${PORT:-80}"
HOST_PORT="${HOST_PORT:-8080}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LOG_GROUP="${LOG_GROUP:-/sentinel-sample/timeout-service}"

if [[ -z "${CHAOS_TOKEN:-}" ]]; then
  printf 'Export CHAOS_TOKEN (at least 32 characters) before deployment; keep it securely for /admin/chaos.\n' >&2
  exit 1
fi

if [[ ${#CHAOS_TOKEN} -lt 32 ]]; then
  printf 'CHAOS_TOKEN must be at least 32 characters.\n' >&2
  exit 1
fi

sudo docker info >/dev/null
sudo install -d -o "$(id -un)" -g "$(id -gn)" "$APP_DIR"
BUILD_DIR="$(mktemp -d "$APP_DIR/build.XXXXXX")"
trap 'rm -rf -- "$BUILD_DIR"' EXIT

printf 'Cloning a fresh copy of %s (branch %s)...\n' "$REPO_URL" "$REPO_BRANCH"
git clone --depth 1 --single-branch --branch "$REPO_BRANCH" -- "$REPO_URL" "$BUILD_DIR/source"

printf 'Building %s from scratch...\n' "$IMAGE_NAME"
sudo docker build --pull --no-cache -t "$IMAGE_NAME" "$BUILD_DIR/source"

# Keep the existing service running until the new image builds successfully.
# Remove only this service's container, never unrelated containers or volumes.
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
  -e HOST="0.0.0.0" \
  -e NODE_ENV="production" \
  "$IMAGE_NAME"

sudo docker ps --filter name=timeout-service --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
printf 'Waiting for the service health endpoint...\n'
# Docker can publish the port before Node listens, causing resets (curl exit 56).
# Retry all failures for this read-only GET, not just connection refusals/HTTP 5xx.
if ! curl --fail --silent --show-error --retry 20 --retry-all-errors \
  --retry-delay 2 --retry-max-time 90 --max-time 5 --output /dev/null "http://127.0.0.1:$PORT/healthz"; then
  printf 'Service did not become healthy within the startup retry budget. Check container logs in CloudWatch.\n' >&2
  sudo docker inspect --format 'State={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{end}} Restarts={{.RestartCount}} ExitCode={{.State.ExitCode}}' timeout-service >&2 || true
  exit 1
fi

printf '\nService is running at http://127.0.0.1:%s\n' "$PORT"
if [[ -n "${PUBLIC_IP:-}" ]]; then
  printf 'Public health check (allowed networks only): http://%s.sslip.io:%s/healthz\n' "$PUBLIC_IP" "$PORT"
fi

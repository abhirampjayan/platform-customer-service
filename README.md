# timeout-service

A small HTTP service that deliberately runs out of time. It calls a simulated downstream
ledger, abandons the call once a request deadline passes, answers `504`, and writes one
structured JSON line describing the failure. That line is what CloudWatch alarms on and what
Sentinel Ops will read once the investigation provider ships.

This is a standalone project. It is **not** part of the Sentinel monorepo — the root
`package.json` only globs `apps/*` and `packages/*`, so nothing here is installed, built or
linted by `yarn build` at the repo root. It is deployed on its own.

To register it with Sentinel, see [connect.md](connect.md).

## Endpoints

| Method | Path | Behaviour |
| --- | --- | --- |
| `GET` | `/healthz` | Liveness. Never touches the ledger, so it stays `200` while the service is timing out. |
| `GET` | `/readyz` | Calls the ledger on a tighter 1s budget. `200` when reachable, `503` when not. |
| `GET` | `/api/orders/:orderId` | The business route. `200` normally, `504` when the ledger misses the deadline. |
| `GET` | `/api/slow?ms=N` | Deterministic trigger. Any `ms` above `REQUEST_DEADLINE_MS` returns `504`. |
| `GET` | `/admin/chaos` | Current upstream behaviour. Requires `Authorization: Bearer $CHAOS_TOKEN`. |
| `POST` | `/admin/chaos` | Changes `latencyMs`, `jitterMs` or `timeoutRate` at runtime. Same bearer token. |

`/readyz` logs `event: "readiness.degraded"` rather than `upstream.timeout`, so a probe
running every few seconds does not inflate the alarm metric.

## The log line that matters

Every timeout produces exactly one of these. The field names are a contract: the CloudWatch
metric filter matches `$.event`, so renaming it silently breaks the alarm.

```json
{
  "level": "error",
  "time": "2026-09-22T05:20:33.795Z",
  "service": "timeout-service",
  "env": "production",
  "version": "1.0.0",
  "reqId": "47c5e4df-bc48-4723-975e-0e97e8d82790",
  "event": "upstream.timeout",
  "requestId": "47c5e4df-bc48-4723-975e-0e97e8d82790",
  "route": "GET /api/orders/:orderId",
  "upstream": "ledger",
  "operation": "orders.read:ord_123",
  "deadlineMs": 3000,
  "elapsedMs": 3001,
  "statusCode": 504,
  "msg": "upstream call exceeded the request deadline"
}
```

## Configuration

| Variable | Default | Notes |
| --- | --- | --- |
| `CHAOS_TOKEN` | — | **Required**, minimum 32 characters. The service refuses to start without it. |
| `PORT` | `8080` | |
| `HOST` | `0.0.0.0` | |
| `NODE_ENV` | `development` | Reported as `env` on every log line. |
| `LOG_LEVEL` | `info` | |
| `SERVICE_NAME` | `timeout-service` | |
| `SERVICE_VERSION` | `1.0.0` | |
| `REQUEST_DEADLINE_MS` | `3000` | How long a request may wait on the ledger before it becomes a `504`. |
| `UPSTREAM_LATENCY_MS` | `200` | Baseline ledger latency. |
| `UPSTREAM_JITTER_MS` | `80` | Random band added to every call. |
| `UPSTREAM_TIMEOUT_RATE` | `0` | Fraction of calls (0–1) that hang past the deadline regardless of latency. |

A bad value is fatal at boot rather than at request time, so a misconfigured container dies
immediately instead of serving nonsense.

## Run it locally

```bash
cd sample-apps/timeout-service
cp .env.example .env          # then put a real CHAOS_TOKEN in it
npm install
npm run build

export CHAOS_TOKEN="$(openssl rand -hex 24)"
npm start
```

Prove the failure mode:

```bash
curl -s localhost:8080/healthz
curl -s localhost:8080/api/orders/ord_123                 # 200
curl -s "localhost:8080/api/slow?ms=5000"                 # 504

# Or flip the whole service into a failing state:
curl -s -X POST localhost:8080/admin/chaos \
  -H "authorization: Bearer $CHAOS_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"latencyMs":5000}'
curl -s localhost:8080/api/orders/ord_123                 # now 504
```

In Docker:

```bash
docker build -t timeout-service:local .
docker run --rm -p 8080:8080 -e CHAOS_TOKEN="$CHAOS_TOKEN" timeout-service:local
```

## Deploy to EC2 from your local machine

Before you can SSH into the EC2 instance, update the firewall rule with the public IP your
current network is using. Run this from any machine that can reach the internet:

```bash
curl -s https://checkip.amazonaws.com
```

Example output:

```bash
103.210.133.108
```

Use that value in `deploy/terraform/terraform.tfvars`:

```hcl
operator_cidr = "103.210.133.108/32"
```

Then apply the Terraform change so the security group allows your current address:

```bash
cd deploy/terraform
terraform apply
```

After the instance is reachable, make sure Docker Desktop is running locally, then deploy the
app with the helper script:

```bash
cd ../..
export SSH_KEY="$HOME/Downloads/platform-service.pem"
export PUBLIC_IP="$(terraform -chdir=deploy/terraform output -raw public_ip)"
export CHAOS_TOKEN="$(openssl rand -hex 24)"
./deploy/deploy-local.sh
```

The script will:

- clone a fresh copy of `https://github.com/abhirampjayan/platform-customer-service.git`
  (`main` by default; set `REPO_BRANCH` to deploy another branch)
- build the Docker image locally for `linux/arm64` with `--pull --no-cache`
- transfer it to the EC2 instance
- remove the existing `timeout-service` container only after the new image is ready
- start a new container on port 80, leaving unrelated containers and volumes untouched
- verify the app health endpoint

Local uncommitted changes are **not** deployed: push the desired changes to the selected
repository branch first. Both [deploy/deploy-local.sh](deploy/deploy-local.sh) and
[deploy/deploy-ec2.sh](deploy/deploy-ec2.sh) require `CHAOS_TOKEN` to be exported (at least
32 characters); neither prints the token. Keep it securely for admin requests.

For an on-instance build, run [deploy/deploy-ec2.sh](deploy/deploy-ec2.sh) on EC2 instead.
It also uses a fresh clone and uncached build, with temporary source under
`/opt/platform-customer-service` by default. Temporary clones are cleaned up on exit;
existing working copies are not reset or deleted. Both scripts accept `PORT` (public port,
default `80`) and `HOST_PORT` (container port, default `8080`). Terraform allows port 80;
using another public port also requires a matching security-group rule.

Check the app after deployment:

```bash
export SERVICE_URL="$(terraform -chdir=deploy/terraform output -raw service_url)"
curl -s "$SERVICE_URL/healthz"
```

Terraform exposes `http://<elastic-ip>.sslip.io` as `service_url`. For example, an Elastic IP
of `52.6.47.252` gives `http://52.6.47.252.sslip.io`. The public `sslip.io` DNS service resolves
the embedded IP automatically; no purchased domain, Route 53 hosted zone, or DNS record is
needed. Traffic goes directly to the instance's Elastic IP on port 80, not through a proxy.
The raw Elastic IP still works for HTTP and SSH.

Use **HTTP**, not HTTPS: `sslip.io` supplies DNS only, not a TLS certificate. The security
group still permits HTTP and SSH only from `operator_cidr`. Do not set that value to
`0.0.0.0/0` to share the demo, as that would also expose SSH. If other networks need access,
add a separate HTTP-only ingress rule for their CIDRs.

If the raw IP works but the hostname does not resolve, your DNS resolver or VPN may block
wildcard IP domains. Check DNS resolution and try an allowed resolver/network; Terraform
cannot override that restriction. The public subnet must also have a route to an Internet
Gateway; attaching an Elastic IP alone does not make a private subnet public.

If your network IP changes again, repeat the `curl -s https://checkip.amazonaws.com` step and
update `operator_cidr` in `deploy/terraform/terraform.tfvars` before running `terraform apply`
again.

## AWS resources

| Resource | Why |
| --- | --- |
| EC2 `t3.micro`, Amazon Linux 2023 | Runs the container. Free-tier eligible in a new account's first year. |
| EC2 key pair | SSH access to build and run the image. |
| Security group | Ports 80 and 22, from your own address only. |
| IAM role + instance profile | Lets the instance write logs and host metrics. No other permissions. |
| Elastic IP | A stable address to put in `connect.md` and in the Sentinel console. |
| CloudWatch log group `/sentinel-sample/timeout-service` | Where container stdout lands, 7-day retention. |
| Metric filter → `SentinelSample/TimeoutService/UpstreamTimeouts` | Turns the timeout log line into a number. |
| SNS topic + email subscription | Where the alarm goes. |
| CloudWatch alarm | Fires on sustained timeouts. |
| CloudWatch dashboard | Timeouts, host memory, and the raw timeout events side by side. |
| IAM role `SentinelReadOnly` | What Sentinel assumes. Created in [connect.md](connect.md), not here. |

There is no load balancer, no TLS certificate, no custom domain and no database. The service
uses an Elastic IP with a free `sslip.io` hostname. It is plain HTTP on port 80, reachable
only from your own IP, and serves no real data.

## Deploy it to AWS

You need AWS CLI v2, configured with credentials that can create IAM, EC2, CloudWatch and SNS
resources. Every command below is copy-paste; run them from `sample-apps/timeout-service`.

### 0. Shell variables

```bash
export AWS_REGION=us-east-1
export LOG_GROUP=/sentinel-sample/timeout-service
export NAMESPACE=SentinelSample/TimeoutService
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export MY_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
export ALERT_EMAIL=you@example.com

echo "account $ACCOUNT_ID, region $AWS_REGION, your address $MY_CIDR"
```

The region you use here must match the region you enter when onboarding to Sentinel.

### 1. Log group

```bash
aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION"

aws logs put-retention-policy \
  --log-group-name "$LOG_GROUP" --retention-in-days 7 --region "$AWS_REGION"

aws logs tag-resource \
  --resource-arn "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}" \
  --tags Application=timeout-service \
  --region "$AWS_REGION"
```

The tag is there so a later phase of Sentinel can discover this log group by application
name — nothing reads it today.

### 2. Instance role

```bash
cat > /tmp/ec2-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON

aws iam create-role \
  --role-name TimeoutServiceInstanceRole \
  --assume-role-policy-document file:///tmp/ec2-trust.json

aws iam attach-role-policy \
  --role-name TimeoutServiceInstanceRole \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

cat > /tmp/logs-write.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ],
    "Resource": "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}:*"
  }]
}
JSON

aws iam put-role-policy \
  --role-name TimeoutServiceInstanceRole \
  --policy-name WriteTimeoutServiceLogs \
  --policy-document file:///tmp/logs-write.json

aws iam create-instance-profile --instance-profile-name TimeoutServiceInstanceProfile
aws iam add-role-to-instance-profile \
  --instance-profile-name TimeoutServiceInstanceProfile \
  --role-name TimeoutServiceInstanceRole
```

The inline policy is scoped to this one log group. `CreateLogGroup` is deliberately absent —
the group already exists with a retention policy, and the Docker log driver is configured not
to create one.

### 3. Security group and key pair

```bash
export VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")"

export SG_ID="$(aws ec2 create-security-group \
  --group-name timeout-service-sg \
  --description 'Sentinel sample timeout service' \
  --vpc-id "$VPC_ID" --query GroupId --output text --region "$AWS_REGION")"

aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 80 --cidr "$MY_CIDR" --region "$AWS_REGION"
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr "$MY_CIDR" --region "$AWS_REGION"

aws ec2 create-key-pair --key-name timeout-service \
  --query KeyMaterial --output text --region "$AWS_REGION" > ~/.ssh/timeout-service.pem
chmod 400 ~/.ssh/timeout-service.pem
```

Both rules are scoped to your address. Widen them only if you understand that this exposes an
unauthenticated HTTP service to the internet.

### 4. Launch the instance

```bash
export AMI_ID="$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text --region "$AWS_REGION")"

export INSTANCE_ID="$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name timeout-service \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile Name=TimeoutServiceInstanceProfile \
  --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
  --user-data file://deploy/user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=timeout-service}]' \
  --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION")"

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
```

`HttpTokens=required` forces IMDSv2, so a request-forgery bug in the app cannot be used to
read the instance credentials.

### 5. Elastic IP

```bash
export ALLOC_ID="$(aws ec2 allocate-address --domain vpc \
  --query AllocationId --output text --region "$AWS_REGION")"

aws ec2 associate-address --instance-id "$INSTANCE_ID" \
  --allocation-id "$ALLOC_ID" --region "$AWS_REGION"

export PUBLIC_IP="$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" \
  --query 'Addresses[0].PublicIp' --output text --region "$AWS_REGION")"
echo "http://$PUBLIC_IP"
```

### 6. Build and run the container on the instance

The image is built on the instance from a clone of this repository, which avoids standing up
ECR for a sample app.

```bash
ssh -i ~/.ssh/timeout-service.pem ec2-user@"$PUBLIC_IP"
```

Then, on the instance:

```bash
# user data finished when this file exists
ls /opt/timeout-service/.bootstrap-complete

cd /opt/timeout-service
git clone <your-fork-url> repo
cd repo/sample-apps/timeout-service

docker build -t timeout-service:latest .

# Keep the token out of shell history and out of `docker inspect` output.
openssl rand -hex 24 > /opt/timeout-service/chaos-token
chmod 600 /opt/timeout-service/chaos-token

docker run -d \
  --name timeout-service \
  --restart unless-stopped \
  -p 80:8080 \
  -e NODE_ENV=production \
  -e CHAOS_TOKEN="$(cat /opt/timeout-service/chaos-token)" \
  --log-driver awslogs \
  --log-opt awslogs-region=us-east-1 \
  --log-opt awslogs-group=/sentinel-sample/timeout-service \
  --log-opt awslogs-stream=app \
  --log-opt awslogs-create-group=false \
  timeout-service:latest

curl -s localhost/healthz
```

The `awslogs` driver ships container stdout straight to CloudWatch. No log agent is involved
in that path, which is why the instance role only needs `PutLogEvents`.

### 7. Host metrics

The CloudWatch agent is installed by user data but not configured, because EC2 does not
publish memory or disk usage on its own. Still on the instance:

```bash
sudo cp /opt/timeout-service/repo/sample-apps/timeout-service/deploy/cloudwatch-agent-config.json \
  /opt/aws/amazon-cloudwatch-agent/etc/timeout-service.json

sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/timeout-service.json
```

### 8. Metric filter, alarm and dashboard

Back on your own machine:

```bash
aws logs put-metric-filter \
  --log-group-name "$LOG_GROUP" \
  --filter-name upstream-timeouts \
  --filter-pattern '{ $.event = "upstream.timeout" }' \
  --metric-transformations \
    "metricName=UpstreamTimeouts,metricNamespace=${NAMESPACE},metricValue=1,defaultValue=0" \
  --region "$AWS_REGION"

export TOPIC_ARN="$(aws sns create-topic --name timeout-service-alerts \
  --query TopicArn --output text --region "$AWS_REGION")"

aws sns subscribe --topic-arn "$TOPIC_ARN" \
  --protocol email --notification-endpoint "$ALERT_EMAIL" --region "$AWS_REGION"
# confirm the subscription from your inbox before the alarm can reach you

aws cloudwatch put-metric-alarm \
  --alarm-name timeout-service-upstream-timeouts \
  --alarm-description 'timeout-service abandoned three or more ledger calls in a minute' \
  --namespace "$NAMESPACE" \
  --metric-name UpstreamTimeouts \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 3 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$TOPIC_ARN" \
  --region "$AWS_REGION"
```

`defaultValue=0` makes the metric report a zero for quiet minutes, so the alarm has a
continuous series to evaluate instead of flapping in and out of `INSUFFICIENT_DATA`.

The dashboard:

```bash
cat > /tmp/dashboard.json <<JSON
{
  "widgets": [
    {
      "type": "metric", "x": 0, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "Upstream timeouts",
        "region": "${AWS_REGION}",
        "view": "timeSeries", "stat": "Sum", "period": 60,
        "metrics": [["${NAMESPACE}", "UpstreamTimeouts"]]
      }
    },
    {
      "type": "metric", "x": 12, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "Host memory used",
        "region": "${AWS_REGION}",
        "view": "timeSeries", "stat": "Average", "period": 60,
        "metrics": [["${NAMESPACE}", "mem_used_percent"]]
      }
    },
    {
      "type": "log", "x": 0, "y": 6, "width": 24, "height": 8,
      "properties": {
        "title": "Recent timeouts",
        "region": "${AWS_REGION}",
        "view": "table",
        "query": "SOURCE '${LOG_GROUP}' | fields @timestamp, route, operation, deadlineMs, elapsedMs, requestId | filter event = 'upstream.timeout' | sort @timestamp desc | limit 50"
      }
    }
  ]
}
JSON

aws cloudwatch put-dashboard \
  --dashboard-name timeout-service \
  --dashboard-body file:///tmp/dashboard.json \
  --region "$AWS_REGION"
```

### 9. Prove it works end to end

```bash
curl -s "http://$PUBLIC_IP/healthz"
curl -s -o /dev/null -w '%{http_code}\n' "http://$PUBLIC_IP/api/orders/ord_123"   # 200

# Five timeouts, which is comfortably over the alarm threshold.
for i in $(seq 1 5); do
  curl -s -o /dev/null -w '%{http_code}\n' "http://$PUBLIC_IP/api/slow?ms=5000"
done

aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern '{ $.event = "upstream.timeout" }' \
  --start-time "$(( ($(date +%s) - 600) * 1000 ))" \
  --query 'events[].message' --output text --region "$AWS_REGION"

aws cloudwatch get-metric-statistics \
  --namespace "$NAMESPACE" --metric-name UpstreamTimeouts \
  --start-time "$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --statistics Sum --region "$AWS_REGION"

aws cloudwatch describe-alarms --alarm-names timeout-service-upstream-timeouts \
  --query 'MetricAlarms[0].StateValue' --output text --region "$AWS_REGION"
```

Metric filters only evaluate events that arrive after the filter is created, so run the
requests *after* step 8. The alarm takes a minute or two to move to `ALARM`, and the email
only arrives once you have confirmed the SNS subscription.

Now go to [connect.md](connect.md) and register the application in Sentinel.

## Tear it down

```bash
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
aws ec2 release-address --allocation-id "$ALLOC_ID" --region "$AWS_REGION"
aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION"
aws ec2 delete-key-pair --key-name timeout-service --region "$AWS_REGION"

aws cloudwatch delete-alarms --alarm-names timeout-service-upstream-timeouts --region "$AWS_REGION"
aws cloudwatch delete-dashboards --dashboard-names timeout-service --region "$AWS_REGION"
aws sns delete-topic --topic-arn "$TOPIC_ARN" --region "$AWS_REGION"
aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION"

aws iam remove-role-from-instance-profile \
  --instance-profile-name TimeoutServiceInstanceProfile --role-name TimeoutServiceInstanceRole
aws iam delete-instance-profile --instance-profile-name TimeoutServiceInstanceProfile
aws iam delete-role-policy --role-name TimeoutServiceInstanceRole --policy-name WriteTimeoutServiceLogs
aws iam detach-role-policy --role-name TimeoutServiceInstanceRole \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws iam delete-role --role-name TimeoutServiceInstanceRole
```

The Elastic IP is billed while it is allocated but not associated with a running instance, so
release it rather than leaving it behind. `SentinelReadOnly` is deleted separately — see
[connect.md](connect.md).

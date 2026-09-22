# Deploy timeout-service from the AWS Console

This guide explains how to create the AWS resources in the AWS Management Console, build the Docker image, deploy it to EC2, and verify the app.

## 1. Create the VPC

1. Sign in to AWS Console.
2. Open the VPC service.
3. Click Create VPC.
4. Choose VPC and more.
5. Fill in:
   - Name: `timeout-service`
   - IPv4 CIDR: `10.0.0.0/16`
   - Number of AZs: `1`
   - Public subnets: `1`
   - Private subnets: `0`
   - NAT Gateway: `None`
6. Click Create VPC.

After creation, copy the VPC ID and the public subnet ID.

## 2. Create the public subnet

1. Open VPC > Subnets.
2. Select the created subnet.
3. Confirm it is public and has Auto-assign public IPv4 address enabled.
4. Copy the subnet ID.

## 3. Create the EC2 key pair

1. Open EC2.
2. Go to Key Pairs.
3. Click Create key pair.
4. Name it `platform-service`.
5. Download the `.pem` file and keep it in a safe location.

Example:

```bash
chmod 400 ~/Downloads/platform-service.pem
```

## 4. Find your public IP

Run this on your local machine:

```bash
curl -s https://checkip.amazonaws.com
```

If it returns `103.210.133.108`, use:

```hcl
operator_cidr = "103.210.133.108/32"
```

This is the only IP allowed to reach the EC2 instance over SSH and HTTP.

## 5. Create the Terraform variables file

In this repo, create:

```bash
cd deploy/terraform
cp terraform.tfvars.example terraform.tfvars
```

Then edit `terraform.tfvars` with your real values:

```hcl
aws_region    = "us-east-1"
vpc_id        = "vpc-xxxxxxxxxxxxxxxxx"
subnet_id     = "subnet-xxxxxxxxxxxxxxxxx"
key_name      = "platform-service"
operator_cidr = "103.210.133.108/32"
alert_email   = "you@example.com"
```

## 6. Apply the Terraform

Run:

```bash
terraform init
terraform plan
terraform apply
```

When it finishes, note:

```bash
terraform output public_ip
```

Example:

```text
52.71.202.118
```

## 7. SSH into the EC2 instance

From your machine:

```bash
ssh -i ~/Downloads/platform-service.pem ec2-user@52.71.202.118
```

If your IP changes, update `operator_cidr` and run Terraform again before trying to connect.

## 8. Build and deploy the app on EC2

Once you are connected to the EC2 instance, run:

```bash
sudo yum update -y
sudo yum install -y docker git
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
```

Then log out and log back in, or run:

```bash
newgrp docker
```

Clone the project and build the image:

```bash
git clone https://github.com/abhirampjayan/timeout-service.git /opt/timeout-service
cd /opt/timeout-service
export CHAOS_TOKEN="$(openssl rand -hex 24)"
```

Build the Docker image:

```bash
docker build -t timeout-service:local .
```

Run the container on port 80:

```bash
docker run -d \
  --name timeout-service \
  --restart unless-stopped \
  -p 80:8080 \
  --log-driver awslogs \
  --log-opt awslogs-region=us-east-1 \
  --log-opt awslogs-group=/sentinel-sample/timeout-service \
  --log-opt awslogs-stream=timeout-service \
  -e CHAOS_TOKEN="$CHAOS_TOKEN" \
  -e PORT=8080 \
  -e HOST=0.0.0.0 \
  -e NODE_ENV=production \
  timeout-service:local
```

## 9. Verify the app

From your local machine:

```bash
curl -i http://52.71.202.118/healthz
```

Expected response:

```text
HTTP/1.1 200 OK
```

Also test:

```bash
curl -i http://52.71.202.118/api/orders/ord_123
curl -i "http://52.71.202.118/api/slow?ms=5000"
```

The second request should return `200` and the slow one should return `504`.

## 10. Admin route

To change runtime behavior, call the admin route:

```bash
curl -i -X POST http://52.71.202.118/admin/chaos \
  -H "Authorization: Bearer $CHAOS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"latencyMs":5000}'
```

## 11. If your IP changes

Your public IP can shift depending on your ISP or VPN. When that happens:

```bash
curl -s https://checkip.amazonaws.com
```

Update `operator_cidr` in the Terraform file and rerun:

```bash
terraform -chdir=deploy/terraform apply
```

Without updating this value, SSH and HTTP access will time out.

## 12. Useful AWS console checks

Check the following in the AWS Console:

- EC2 > Instances: instance is running
- EC2 > Security Groups: port 22 and 80 are allowed from your IP
- CloudWatch > Log groups: `/sentinel-sample/timeout-service`
- CloudWatch > Alarms: `timeout-service-upstream-timeouts`

This is the full console-based deployment flow for the project.

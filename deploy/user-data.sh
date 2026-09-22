#!/bin/bash
# EC2 user data for Amazon Linux 2023. Installs Docker, git and the CloudWatch agent,
# then prepares /opt/timeout-service. Passed to `aws ec2 run-instances --user-data`;
# it runs once, as root, on first boot. Progress lands in /var/log/cloud-init-output.log.
set -euxo pipefail

dnf update -y
dnf install -y docker git amazon-cloudwatch-agent

systemctl enable --now docker
usermod -aG docker ec2-user

install -d -o ec2-user -g ec2-user /opt/timeout-service

# Container stdout goes to CloudWatch through Docker's awslogs driver, so the agent is
# only here for the host memory and disk metrics EC2 does not publish on its own.
# The config is uploaded separately, after the instance is up.

touch /opt/timeout-service/.bootstrap-complete

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

install -d /opt/aws/amazon-cloudwatch-agent/etc
cat >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'JSON'
{
	"agent": {
		"metrics_collection_interval": 60,
		"run_as_user": "cwagent"
	},
	"metrics": {
		"namespace": "SentinelSample/TimeoutService",
		"append_dimensions": {
			"InstanceId": "${aws:InstanceId}"
		},
		"aggregation_dimensions": [["InstanceId"]],
		"metrics_collected": {
			"mem": {
				"measurement": ["mem_used_percent"],
				"metrics_collection_interval": 60
			},
			"disk": {
				"measurement": ["used_percent"],
				"resources": ["/"],
				"metrics_collection_interval": 60
			}
		}
	}
}
JSON

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
	-a fetch-config \
	-m ec2 \
	-c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
	-s

touch /opt/timeout-service/.bootstrap-complete

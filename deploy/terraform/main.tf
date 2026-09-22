terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["137112412989"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-6.1-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_cloudwatch_log_group" "service" {
  name              = "/sentinel-sample/timeout-service"
  retention_in_days = 7

  tags = local.tags
}

resource "aws_sns_topic" "timeouts" {
  name = "timeout-service-timeouts"

  tags = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.timeouts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_log_metric_filter" "upstream_timeouts" {
  name           = "timeout-service-upstream-timeouts"
  log_group_name = aws_cloudwatch_log_group.service.name
  pattern        = "{ $.event = \"upstream.timeout\" }"

  metric_transformation {
    name          = "UpstreamTimeouts"
    namespace     = "SentinelSample/TimeoutService"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "upstream_timeouts" {
  alarm_name          = "timeout-service-upstream-timeouts"
  alarm_description   = "Timeout Service is reporting upstream ledger timeouts."
  namespace           = "SentinelSample/TimeoutService"
  metric_name         = aws_cloudwatch_log_metric_filter.upstream_timeouts.metric_transformation[0].name
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.timeout_alarm_threshold
  evaluation_periods  = 1
  period              = 300
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.timeouts.arn]
  ok_actions    = [aws_sns_topic.timeouts.arn]

  tags = local.tags
}

resource "aws_iam_role" "instance" {
  name = "timeout-service-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "container_logs" {
  name = "timeout-service-container-logs"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents",
      ]
      Resource = "${aws_cloudwatch_log_group.service.arn}:*"
    }]
  })
}

resource "aws_iam_instance_profile" "service" {
  name = "timeout-service-instance"
  role = aws_iam_role.instance.name
}

resource "aws_security_group" "service" {
  name        = "timeout-service"
  description = "Timeout Service HTTP and SSH access"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from the operator network"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }

  ingress {
    description = "SSH from the operator network"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "timeout-service" })
}

resource "aws_instance" "service" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.service.name
  vpc_security_group_ids = [aws_security_group.service.id]
  user_data              = file("${path.module}/../user-data.sh")

  root_block_device {
    volume_size = 16
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.tags, { Name = "timeout-service" })
}

resource "aws_eip" "service" {
  domain = "vpc"

  tags = merge(local.tags, { Name = "timeout-service" })
}

resource "aws_eip_association" "service" {
  allocation_id = aws_eip.service.id
  instance_id   = aws_instance.service.id
}

resource "aws_cloudwatch_dashboard" "service" {
  dashboard_name = "timeout-service"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          region  = var.aws_region
          title   = "Upstream timeouts"
          view    = "timeSeries"
          metrics = [["SentinelSample/TimeoutService", "UpstreamTimeouts"]]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          region  = var.aws_region
          title   = "Host memory used"
          view    = "timeSeries"
          metrics = [["SentinelSample/TimeoutService", "mem_used_percent", "InstanceId", aws_instance.service.id]]
        }
      },
      {
        type   = "log"
        width  = 24
        height = 6
        properties = {
          region = var.aws_region
          title  = "Upstream timeout events"
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.service.name}' | fields @timestamp, route, operation, elapsedMs | filter event = \"upstream.timeout\" | sort @timestamp desc | limit 20"
        }
      },
    ]
  })
}

locals {
  tags = {
    Application = "timeout-service"
    ManagedBy   = "terraform"
  }
}
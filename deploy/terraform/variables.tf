variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_id" {
  type        = string
  description = "VPC where the service instance will run."
}

variable "subnet_id" {
  type        = string
  description = "Public subnet for the service instance."
}

variable "key_name" {
  type        = string
  description = "Existing EC2 key pair name for operator SSH access."
}

variable "operator_cidr" {
  type        = string
  description = "Public CIDR allowed to access HTTP and SSH, for example 203.0.113.4/32."
}

variable "alert_email" {
  type        = string
  description = "Email address that receives timeout alarms."
}

variable "instance_type" {
  type    = string
  default = "t4g.micro"
}

variable "timeout_alarm_threshold" {
  type    = number
  default = 1
}
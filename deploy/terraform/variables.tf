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

# Hackathon: Sentinel runs locally against this same AWS account rather than
# from a deployed EC2 instance, so the trust policy names the IAM identity the
# local process assumes-role as, not an instance role.
variable "sentinel_principal_arn" {
  type        = string
  description = "The IAM principal (user or role) Sentinel calls AssumeRole as. Null skips creating the role."
  default     = null
}

variable "sentinel_external_id" {
  type        = string
  description = "External ID shown on the application's connection page in the Sentinel console."
  default     = null
}
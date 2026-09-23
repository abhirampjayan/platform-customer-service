output "instance_id" {
  value = aws_instance.service.id
}

output "public_ip" {
  value       = aws_eip.service.public_ip
  description = "Stable Elastic IP for SSH and direct HTTP access."
}

output "service_url" {
  value       = "http://${aws_eip.service.public_ip}.sslip.io"
  description = "HTTP URL resolving to the Elastic IP through sslip.io; no custom domain or TLS certificate required. Access is restricted to operator_cidr."
  depends_on  = [aws_eip_association.service]
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.service.name
}

output "sns_subscription_confirmation_required" {
  value = "Confirm the subscription email sent to ${var.alert_email} before notifications can be delivered."
}

output "sentinel_read_only_role_arn" {
  value       = try(aws_iam_role.sentinel_read_only[0].arn, null)
  description = "Paste into the application's AWS connection in the Sentinel console, then verify."
}
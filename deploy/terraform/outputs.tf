output "instance_id" {
  value = aws_instance.service.id
}

output "public_ip" {
  value = aws_eip.service.public_ip
}

output "service_url" {
  value = "http://${aws_eip.service.public_ip}"
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.service.name
}

output "sns_subscription_confirmation_required" {
  value = "Confirm the subscription email sent to ${var.alert_email} before notifications can be delivered."
}
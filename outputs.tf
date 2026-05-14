# Outputs file
output "catapp_url" {
  value = "http://${aws_eip.hashicat.public_dns}"
}

output "catapp_ip" {
  value = "http://${aws_eip.hashicat.public_ip}"
}

output "codekeeper_test_alerts_arn" {
  value       = aws_sns_topic.codekeeper_test_alerts.arn
  description = "ARN of the codekeeper-test-alerts SNS topic."
}

output "instance_id" {
  description = "The operator scripts find the box by its Box tag, not by this output."
  value       = aws_instance.box.id
}

output "ami_id" {
  value = aws_instance.box.ami
}

output "piri_bucket_prefix" {
  description = "Prefix of the six piri bucket names; the store name completes each."
  value       = local.piri_bucket_prefix
}

output "role_name" {
  value = aws_iam_role.box.name
}

output "user_data" {
  description = "The first-boot script, for the roots' tests."
  value       = aws_instance.box.user_data
}

output "tags" {
  value = aws_instance.box.tags
}

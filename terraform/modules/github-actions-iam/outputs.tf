output "role_arns" {
  description = "ARN of each role by its short name (plan, apply, results), for the workflow env blocks."
  value       = { for k, r in aws_iam_role.this : k => r.arn }
}

# The rendered documents, so the bootstrap root's tests can check what each
# role is allowed without an AWS account.
output "policy_json" {
  description = "Permissions policy of each role by its short name."
  value       = { for k, r in local.roles : k => r.policy }
}

output "trust_policy_json" {
  description = "Trust policy of each role by its short name."
  value       = { for k, d in data.aws_iam_policy_document.assume : k => d.json }
}

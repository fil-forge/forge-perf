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

output "box_permissions_boundary_arn" {
  description = "Boundary every box root sets as its instance role's permissions_boundary. The apply role cannot create a box role without it."
  value       = aws_iam_policy.box_boundary.arn
}

output "box_boundary_policy_json" {
  description = "The boundary's rendered document, for the tests."
  value       = data.aws_iam_policy_document.box_boundary.json
}

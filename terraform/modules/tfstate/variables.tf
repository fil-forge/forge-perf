variable "bucket_name" {
  description = "Globally unique name for the state bucket. By convention forge-nodes-tfstate-<account_id>, so the name says which account's state it holds; the backend blocks in terraform/envs hard-code it, because a backend block cannot read a variable."
  type        = string
}

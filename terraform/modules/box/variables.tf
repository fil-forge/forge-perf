variable "box_name" {
  description = "The box's ID: names its resources, its piri buckets, its results prefixes and its run IDs. `main` for the persistent box, `campaign` for the tier-3 one."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.box_name))
    error_message = "box_name is 2 to 12 lowercase letters or digits, the shape run IDs and the record schema accept."
  }
}

variable "mode" {
  description = "persistent follows forge_perf_ref and dispatches runs from its timers; campaign stays at its bootstrap commit and runs one set. Picks systemd/enabled.<mode>."
  type        = string

  validation {
    condition     = contains(["persistent", "campaign"], var.mode)
    error_message = "mode is persistent or campaign."
  }
}

variable "instance_type" {
  description = "An m9gd size. Changed in place: the provider stops, modifies and starts the same instance, and the host reads the new type from instance metadata."
  type        = string
}

variable "architecture" {
  description = "CPU architecture of the AMI and the instance type, checked against both before launch."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "amd64"], var.architecture)
    error_message = "architecture is arm64 or amd64."
  }
}

variable "ami_id" {
  description = "The pinned Ubuntu 24.04 image, from the constants module. A new value replaces the instance, which the host records as an instrument change."
  type        = string
}

variable "root_volume_size" {
  description = "Root gp3 volume in GB: the OS, Docker's image store, Go caches, checkouts and journald. Run data lives on the instance store."
  type        = number
  default     = 100
}

variable "expires_at" {
  description = "RFC 3339 time after which the reaper destroys the box, set as the ExpiresAt tag. null for the persistent box."
  type        = string
  default     = null
}

variable "forge_perf_ref" {
  description = "The branch or full commit the box clones at first boot and, in persistent mode, follows."
  type        = string
  default     = "main"
}

variable "repository_url" {
  description = "Where the box clones forge-perf from. Public, so the clone needs no credential."
  type        = string
  default     = "https://github.com/fil-forge/forge-perf.git"
}

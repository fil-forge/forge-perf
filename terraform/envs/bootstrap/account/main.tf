# Bootstrap for the dev account: the state bucket every other root in this
# repository keeps its state in.
#
# It lives in its own root because of a chicken-and-egg problem. The bucket is
# what every other root's backend points at, so it cannot be created by an
# apply that already keeps its state there. So this root is applied by hand,
# once, and everything downstream of it is ordinary. versions.tofu gives the
# procedure.

provider "aws" {
  region = module.constants.region

  # A bucket created in the wrong account is invisible until another root fails
  # to reach it, so name the account this root belongs to and let a mismatch
  # fail at plan time instead.
  allowed_account_ids = [module.constants.nonprod_account_id]

  default_tags {
    tags = {
      Project = "forge-perf"
    }
  }
}

module "constants" {
  source = "../../../modules/shared/constants"
}

module "tfstate" {
  source = "../../../modules/tfstate"

  # Hard-coded in every backend block in this repository, so it cannot be
  # derived there the way it is here. Stated in the same shape those blocks
  # state it, and guarded by allowed_account_ids above.
  bucket_name = "${module.constants.state_bucket_name_prefix}-${module.constants.nonprod_account_id}"
}

output "state_bucket_name" {
  value = module.tfstate.bucket_name
}

# Remote state in the bucket created by terraform/bootstrap. The bucket name and
# region are passed at init time (make init), so no account ID lives in Git.
terraform {
  backend "s3" {
    key          = "lab/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

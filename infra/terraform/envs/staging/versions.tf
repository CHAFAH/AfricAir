terraform {
  required_version = "~> 1.13" # >= 1.10 for S3 native state locking (use_lockfile)

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
  }

  # Partial configuration: terraform init -backend-config=backend.hcl (bucket from ../../bootstrap).
  backend "s3" {
    key          = "africair/staging/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true # a .tflock object next to the state: a second plan/apply waits or fails
  }
}

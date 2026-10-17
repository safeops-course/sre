# Where Terraform keeps the state of the AWS foundation: the same Cloudflare R2 bucket as the other
# modules, under its own key. R2 speaks the S3 API, so the "s3" backend is used with an R2 endpoint
# (see hcloud_cluster/backend.tf for the reasons behind each setting).
# The R2 keys come from the environment (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY), never from this file.
# The backend takes them; the aws provider does not (its profile wins, versions.tf).
terraform {
  backend "s3" {
    bucket = "sre"
    key    = "tfstate/aws/foundation.tfstate"
    region = "auto"

    endpoints = {
      s3 = "https://99c9887cccb1cb265d748f267999af47.r2.cloudflarestorage.com"
    }

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    use_lockfile                = true
  }
}

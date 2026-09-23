terraform {
  backend "s3" {
    bucket = "sre"
    key    = "tfstate/hcloud/cluster.tfstate"
    region = "auto"

    # Cloudflare R2 S3-compatible endpoint (account-specific).
    endpoints = {
      s3 = "https://99c9887cccb1cb265d748f267999af47.r2.cloudflarestorage.com"
    }

    # Required for non-AWS S3 backends.
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true

    # Use S3-native locking (no DynamoDB).
    use_lockfile = true
  }
}


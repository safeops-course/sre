# Runtime secrets for the local (kind) Flux profile.
#
# On Hetzner these come from SOPS-encrypted manifests under flux/secrets/, keyed
# to the platform's age key. A learner does not have that key, so for the local
# profile Terraform generates equivalent secrets once per cluster:
#   - backend-secrets   (jwt-secret, uptrace-dsn)                  in each env namespace
#   - app-postgres-app  (CNPG owner credentials)                   in each env namespace
#   - cnpg-backup-s3    (MinIO instead of Hetzner Object Storage) in each env namespace
#   - minio-credentials (MinIO root user)                          in the minio namespace
#   - sops-age          from an age key generated on first apply   (see age_key_file)
# Nothing here is written to Git; `terraform destroy` removes it all.
# The generated passwords live in the Terraform state (random_password), so the
# state file is a secret too - it is git-ignored, and so is the age key: age_key_file
# must end in .agekey (a validation enforces it), the suffix .gitignore covers.
#
# Every resource here has count or for_each over local_envs: with local_profile = false
# the sets are empty and nothing is created.
# https://developer.hashicorp.com/terraform/language/meta-arguments/for_each
# https://developer.hashicorp.com/terraform/language/meta-arguments/count

# https://developer.hashicorp.com/terraform/language/values/locals
locals {
  local_envs   = var.local_profile ? toset(["develop", "staging", "production"]) : toset([])
  age_key_path = abspath("${path.module}/${var.age_key_file}")
}

# Random values, generated on the first apply and then stable - they are kept in the state.
# special = false: letters and digits only, safe in URLs and connection strings.
# https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password
resource "random_password" "jwt_secret" {
  for_each = local.local_envs
  length   = 48
  special  = false
}

resource "random_password" "postgres_app" {
  for_each = local.local_envs
  length   = 32
  special  = false
}

resource "random_password" "minio_root" {
  count   = var.local_profile ? 1 : 0
  length  = 32
  special = false
}

# The backend's runtime Secret in each environment. depends_on: the namespace must exist first.
# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1
# https://developer.hashicorp.com/terraform/language/meta-arguments/depends_on
resource "kubernetes_secret_v1" "local_backend_secrets" {
  for_each   = local.local_envs
  depends_on = [kubernetes_namespace_v1.bootstrap]

  metadata {
    name      = "backend-secrets"
    namespace = each.key
  }

  type = "Opaque"

  data = {
    "jwt-secret"  = random_password.jwt_secret[each.key].result
    "uptrace-dsn" = var.uptrace_dsn
  }
}

# CNPG bootstrap.initdb.secret expects a kubernetes.io/basic-auth secret.
# https://cloudnative-pg.io/documentation/current/bootstrap/
resource "kubernetes_secret_v1" "local_postgres_app" {
  for_each   = local.local_envs
  depends_on = [kubernetes_namespace_v1.bootstrap]

  metadata {
    name      = "app-postgres-app"
    namespace = each.key
    labels = {
      "cnpg.io/reload" = "true"
    }
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = "app"
    password = random_password.postgres_app[each.key].result
  }

  # CNPG adopts this secret and adds connection keys (host, port, dbname, uri,
  # jdbc-uri, pgpass...) plus its own labels; Terraform only seeds it. ignore_changes stops
  # Terraform from removing them on the next apply.
  # https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle
  lifecycle {
    ignore_changes = [data, metadata[0].labels, metadata[0].annotations]
  }
}

# MinIO's namespace is created here, not by Flux, because its Secret below must exist
# before Flux deploys MinIO. Flux adds its labels; Terraform leaves them alone.
resource "kubernetes_namespace_v1" "minio" {
  count      = var.local_profile ? 1 : 0
  depends_on = [time_sleep.wait_for_cluster]

  metadata {
    name = "minio"
  }

  lifecycle {
    ignore_changes = [metadata[0].labels]
  }
}

# Root user of the in-cluster MinIO; the same password is the CNPG backup key below.
resource "kubernetes_secret_v1" "minio_credentials" {
  count      = var.local_profile ? 1 : 0
  depends_on = [kubernetes_namespace_v1.minio]

  metadata {
    name      = "minio-credentials"
    namespace = "minio"
  }

  type = "Opaque"

  data = {
    MINIO_ROOT_USER     = "sre-backup"
    MINIO_ROOT_PASSWORD = random_password.minio_root[0].result
  }
}

# Same secret name/keys the CNPG clusters reference for Hetzner Object Storage, pointed at MinIO.
# https://cloudnative-pg.io/documentation/current/backup/
resource "kubernetes_secret_v1" "local_cnpg_backup" {
  for_each   = local.local_envs
  depends_on = [kubernetes_namespace_v1.bootstrap]

  metadata {
    name      = "cnpg-backup-s3"
    namespace = each.key
  }

  type = "Opaque"

  data = {
    ACCESS_KEY_ID     = "sre-backup"
    ACCESS_SECRET_KEY = random_password.minio_root[0].result
    BUCKET            = "sre"
    ENDPOINT          = "http://minio.minio.svc.cluster.local:9000"
    REGION            = "auto"
  }
}

# age key for SOPS: generated once, kept outside Git (see .gitignore). A null_resource runs
# a local command (local-exec); the script only creates the key when the file is missing, so
# a re-run never replaces a key your secrets are encrypted to.
# https://github.com/FiloSottile/age
# https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource
# https://developer.hashicorp.com/terraform/language/resources/provisioners/local-exec
resource "null_resource" "age_key" {
  count = var.local_profile ? 1 : 0

  triggers = {
    key_path = local.age_key_path
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOC
      set -euo pipefail
      if [ ! -f "${local.age_key_path}" ]; then
        command -v age-keygen >/dev/null || { echo "age-keygen not found - install age (brew install age / apt install age)"; exit 1; }
        age-keygen -o "${local.age_key_path}"
        echo "generated ${local.age_key_path} - run scripts/sops-setup.sh --local to register it in .sops.yaml"
      fi
    EOC
  }
}

# A data source reads something that already exists - here the key file, for the sops-age
# Secret in main.tf. Reading it puts the key into the state (see sops_age_key in variables.tf).
# https://registry.terraform.io/providers/hashicorp/local/latest/docs/data-sources/file
data "local_file" "age_key" {
  count      = var.local_profile ? 1 : 0
  filename   = local.age_key_path
  depends_on = [null_resource.age_key]
}

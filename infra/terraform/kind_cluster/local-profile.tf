# Runtime secrets for the local (kind) Flux profile.
#
# On Hetzner these come from SOPS-encrypted manifests under flux/secrets/, keyed
# to the platform's age key. A learner does not have that key, so for the local
# profile Terraform generates equivalent secrets once per cluster:
#   - backend-secrets   (jwt-secret, uptrace-dsn, uptrace-headers) in each env namespace
#   - app-postgres-app  (CNPG owner credentials)                   in each env namespace
#   - cnpg-backup-s3    (MinIO instead of R2)                      in each env namespace
#   - minio-credentials (MinIO root user)                          in the minio namespace
#   - sops-age          from an age key generated on first apply   (see age_key_file)
# Nothing here is written to Git; `terraform destroy` removes it all.

locals {
  local_envs   = var.local_profile ? toset(["develop", "staging", "production"]) : toset([])
  age_key_path = abspath("${path.module}/${var.age_key_file}")
}

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

resource "kubernetes_secret" "local_backend_secrets" {
  for_each   = local.local_envs
  depends_on = [kubernetes_namespace.bootstrap]

  metadata {
    name      = "backend-secrets"
    namespace = each.key
  }

  type = "Opaque"

  data = {
    "jwt-secret"      = random_password.jwt_secret[each.key].result
    "uptrace-dsn"     = var.uptrace_dsn
    "uptrace-headers" = ""
  }
}

# CNPG bootstrap.initdb.secret expects a kubernetes.io/basic-auth secret.
resource "kubernetes_secret" "local_postgres_app" {
  for_each   = local.local_envs
  depends_on = [kubernetes_namespace.bootstrap]

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
  # jdbc-uri, pgpass...) plus its own labels; Terraform only seeds it.
  lifecycle {
    ignore_changes = [data, metadata[0].labels, metadata[0].annotations]
  }
}

resource "kubernetes_namespace" "minio" {
  count      = var.local_profile ? 1 : 0
  depends_on = [time_sleep.wait_for_cluster]

  metadata {
    name = "minio"
  }

  lifecycle {
    ignore_changes = [metadata[0].labels]
  }
}

resource "kubernetes_secret" "minio_credentials" {
  count      = var.local_profile ? 1 : 0
  depends_on = [kubernetes_namespace.minio]

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

# Same secret name/keys the CNPG clusters reference for R2, pointed at MinIO.
resource "kubernetes_secret" "local_cnpg_backup" {
  for_each   = local.local_envs
  depends_on = [kubernetes_namespace.bootstrap]

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

# age key for SOPS: generated once, kept outside Git (see .gitignore).
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

data "local_file" "age_key" {
  count      = var.local_profile ? 1 : 0
  filename   = local.age_key_path
  depends_on = [null_resource.age_key]
}

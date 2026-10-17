# The AWS foundation: what stays while EKS clusters come and go. Applied once, by a person, from a
# workstation (it creates the very identity CI deploys with). Nothing here costs money on its own:
# IAM roles and policies, the GitHub OIDC provider, a budget and account defaults are free; cost starts
# with what infra/terraform/eks_cluster creates.
#
#   identity check        only var.expected_principal_arn may plan or apply
#   cluster IAM roles     the EKS cluster, its nodes, the EBS CSI driver and the Load Balancer Controller -
#                         made here, so the deployer never creates or changes an IAM role or policy
#   GitHub OIDC + deployer GitHub Actions of one repository on one ref get short-lived credentials of the
#                         deployer role; no access key exists anywhere
#   budget                warns at 50/90/100 % of spend and at 100 % of the forecast
#   account defaults      S3 public access blocked, EBS encrypted, IMDSv2 required for new instances

# Fail the plan when Terraform runs as anyone else. allowed_account_ids (versions.tf) already keeps it in
# the account; this pins the principal - a workstation can hold several profiles of the same account.
data "aws_caller_identity" "me" {
  lifecycle {
    postcondition {
      condition     = self.arn == var.expected_principal_arn
      error_message = "Terraform authenticates as ${self.arn}, expected ${var.expected_principal_arn}. Sign in with `aws login --profile ${var.aws_profile}` as that identity, or fix TF_VAR_expected_principal_arn."
    }
  }
}

locals {
  account_id = data.aws_caller_identity.me.account_id
}

# ─── Cluster IAM roles ────────────────────────────────────────────────────────
# Every IAM role a cluster needs, made once here: the same idea as gke-nodes in gcp_foundation. The
# deployer may only pass these roles to EKS, EC2 and EKS Pod Identity - it cannot create a role or
# attach a policy, so a workflow run cannot grant itself more than this file does.
# All names start with var.cluster_name; the cluster module uses them with create_iam_role = false.

# The EKS control plane. AmazonEKSClusterPolicy is the AWS-managed minimum for a cluster without Auto Mode.
# https://docs.aws.amazon.com/eks/latest/userguide/cluster-iam-role.html
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-eks-cluster"
  description        = "The EKS control plane of ${var.cluster_name}."
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# The nodes of every managed node group: join the cluster, pull images from ECR, and run the VPC CNI
# (which assigns pod addresses through the node's role).
# https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_nodes" {
  name               = "${var.cluster_name}-eks-nodes"
  description        = "The managed node groups of ${var.cluster_name}."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
  ])

  role       = aws_iam_role.eks_nodes.name
  policy_arn = each.value
}

# The EBS CSI driver (disks for PersistentVolumes), through EKS Pod Identity. AmazonEBSCSIDriverPolicy is
# AWS's own policy for it. The association to the driver's service account is made by the cluster module.
module "ebs_csi_role" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name            = "${var.cluster_name}-ebs-csi"
  use_name_prefix = false
  description     = "EBS CSI driver of ${var.cluster_name} (EKS Pod Identity)."

  additional_policy_arns = {
    ebs_csi = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  }
}

# The AWS Load Balancer Controller (the NLB in front of Traefik), through EKS Pod Identity. AWS publishes
# no managed policy for it; the module keeps the controller's own iam_policy.json - when the controller's
# version moves, check that the module's policy has what the new controller's iam_policy.json lists.
module "aws_lbc_role" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name               = "${var.cluster_name}-aws-lbc"
  use_name_prefix    = false
  description        = "AWS Load Balancer Controller of ${var.cluster_name} (EKS Pod Identity)."
  policy_name_prefix = "${var.cluster_name}-"

  attach_aws_lb_controller_policy = true
}

locals {
  # The roles the deployer may hand to EKS (cluster, node groups, Pod Identity associations).
  cluster_role_arns = [
    aws_iam_role.eks_cluster.arn,
    aws_iam_role.eks_nodes.arn,
    module.ebs_csi_role.iam_role_arn,
    module.aws_lbc_role.iam_role_arn,
  ]
}

# ─── GitHub Actions: OIDC provider and the deployer ───────────────────────────
# GitHub signs a short-lived OIDC token for each workflow run; STS exchanges it for credentials of the
# deployer role. No key is stored in GitHub. The trust policy is the lock: only runs of one repository
# and its owner (by numeric id - a name can be registered again by anyone, an id cannot), on one ref.
# A pull request's code never gets in. AWS checks these GitHub claims itself since 2026-02; it still
# requires a condition on `sub`, which carries the repository's name.
# https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html#condition-keys-wif
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "deployer_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:${var.github_ref}"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository_id"
      values   = [var.github_repository_id]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository_owner_id"
      values   = [var.github_repository_owner_id]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = [var.github_ref]
    }
  }
}

resource "aws_iam_role" "deployer" {
  name                 = "terraform-eks"
  description          = "Assumed by GitHub Actions (OIDC) to build EKS clusters."
  assume_role_policy   = data.aws_iam_policy_document.deployer_assume.json
  max_session_duration = 7200 # a cycle's apply or destroy, with room; the default 1 h is too short for a destroy
}

# What the EKS workflow runs as: enough for a cluster, its network and its node groups in one region,
# nothing more. No IAM writes - the roles above are passed, never made. ec2:* is regional and limited to
# var.region: EKS node groups need launch templates, instances, security groups, the VPC with its NAT,
# and listing the actions one by one would break on every module update.
data "aws_iam_policy_document" "deployer" {
  statement {
    sid     = "EksThisCluster"
    actions = ["eks:*"]
    resources = [
      "arn:aws:eks:${var.region}:${local.account_id}:cluster/${var.cluster_name}",
      "arn:aws:eks:${var.region}:${local.account_id}:*/${var.cluster_name}/*", # node groups, add-ons, access entries, Pod Identity
    ]
  }

  statement {
    sid       = "EksRead"
    actions   = ["eks:Describe*", "eks:List*"] # add-on versions and cluster lists are not per cluster
    resources = ["*"]
  }

  statement {
    sid = "NetworkAndNodesInRegion"
    actions = [
      "ec2:*",
      "autoscaling:Describe*",          # node group instances
      "elasticloadbalancing:Describe*", # the pre-destroy wait for the NLB and `make leftovers`
      "logs:DescribeLogGroups",         # `make leftovers`
      "tag:GetResources",               # `make leftovers`: anything tagged with the cluster
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "PassClusterRoles"
    actions   = ["iam:PassRole"]
    resources = local.cluster_role_arns
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["eks.amazonaws.com", "ec2.amazonaws.com", "pods.eks.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadClusterRoles"
    actions   = ["iam:GetRole"]
    resources = concat(local.cluster_role_arns, [aws_iam_role.deployer.arn])
  }

  # The first cluster in an account creates the roles AWS services act through. Only these services.
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "eks.amazonaws.com",
        "eks-nodegroup.amazonaws.com",
        "autoscaling.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "spot.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role_policy" "deployer" {
  name   = "deploy-eks"
  role   = aws_iam_role.deployer.id
  policy = data.aws_iam_policy_document.deployer.json
}

# ─── Budget ───────────────────────────────────────────────────────────────────
# A budget warns, it never stops spending: the alert is the signal to destroy what was forgotten. The
# amount fits test cycles - create, check, destroy - not a cluster left running (~$9 a day).
resource "aws_budgets_budget" "monthly" {
  name         = "monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_amount)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [
      { type = "ACTUAL", percent = 50 },
      { type = "ACTUAL", percent = 90 },
      { type = "ACTUAL", percent = 100 },
      { type = "FORECASTED", percent = 100 },
    ]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.percent
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = [var.alert_email]
    }
  }
}

# ─── Account defaults ─────────────────────────────────────────────────────────
# Safe defaults for whatever is created later, by any tool. Each is what the CIS AWS Foundations
# Benchmark asks for and costs nothing.

# No S3 bucket or object in the account can be made public (account-wide, every region).
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Every new EBS volume in var.region is encrypted (the AWS-managed key aws/ebs - free).
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# New instances in var.region require IMDSv2 (session tokens), and the token does not travel past the
# instance (hop limit 1): a pod cannot read the node's credentials from the metadata service. A launch
# template may still set its own values - the cluster module's node groups do the same.
resource "aws_ec2_instance_metadata_defaults" "this" {
  http_tokens                 = "required"
  http_put_response_hop_limit = 1
}

# AWS creates a default VPC in every region, with public subnets: an instance launched without a subnet
# gets a public address there. Nothing here uses it (clusters build their own VPC). Terraform did not
# create it, so `make delete-default-vpc CONFIRM=yes` deletes the one in var.region once; this check warns
# on every plan while it (or a re-created one) exists - a warning, not an error.
check "no_default_vpc" {
  data "aws_vpcs" "default" {
    filter {
      name   = "is-default"
      values = ["true"]
    }
  }

  assert {
    condition     = length(data.aws_vpcs.default.ids) == 0
    error_message = "${var.region} has a default VPC (public subnets). Delete it once: make -C infra/terraform/aws_foundation delete-default-vpc CONFIRM=yes"
  }
}

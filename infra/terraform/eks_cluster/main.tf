# An EKS Standard cluster for the platform in this repository - the same platform as on Hetzner and GKE.
# It needs the foundation (infra/terraform/aws_foundation): every IAM role here is made there, so this
# module creates none.
#
#   network      its own VPC in two zones: private subnets for the nodes, public ones for the load
#                balancer and the NAT gateway; an S3 gateway endpoint (free)
#   egress       private nodes (no public IP); the NAT gateway is their only way out
#   control      the API server's public endpoint, IAM decides who gets in (access entries, no aws-auth
#                ConfigMap); a private endpoint for the nodes
#   cluster      VPC CNI with NetworkPolicy (egress too) and prefix delegation, EKS Pod Identity (no IRSA),
#                Kubernetes secrets encrypted with an AWS-owned key, control-plane logs (var)
#   node groups  "platform" and "apps", managed, by role; Spot only where tfvars says so; IMDSv2, hop 1
#   add-ons      VPC CNI, CoreDNS, kube-proxy, Pod Identity agent, EBS CSI driver, metrics-server
#   LBC          the AWS Load Balancer Controller: Traefik's Service gets an NLB (profiles/eks)
#   kubeconfig   kubeconfig.yaml: the endpoint + `aws eks get-token`, no credentials inside
# https://docs.aws.amazon.com/eks/latest/best-practices/introduction.html

# Fail the plan when Terraform runs as anyone else (see aws_foundation/main.tf).
data "aws_caller_identity" "me" {
  lifecycle {
    postcondition {
      condition     = self.arn == var.expected_principal_arn
      error_message = "Terraform authenticates as ${self.arn}, expected ${var.expected_principal_arn}. Sign in with `aws login --profile ${var.aws_profile}` as that identity, or fix TF_VAR_expected_principal_arn."
    }
  }
}

# The roles the foundation made, looked up by name: a missing one fails the plan with "not found" -
# apply the foundation first.
data "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-eks-cluster"
}

data "aws_iam_role" "nodes" {
  name = "${var.cluster_name}-eks-nodes"
}

data "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"
}

data "aws_iam_role" "aws_lbc" {
  name = "${var.cluster_name}-aws-lbc"
}

data "aws_iam_role" "vpc_flow_logs" {
  count = var.flow_logs ? 1 : 0
  name  = "${var.cluster_name}-vpc-flow-logs"
}

locals {
  # The VPC range cut in pieces, in order: a /19 per zone for the nodes and their pods (prefix delegation
  # takes /28 blocks of it, 16 addresses at a time), then a /24 per zone for the load balancer and NAT.
  private_subnets = [for i, _ in var.availability_zones : cidrsubnet(var.vpc_cidr, 3, i)]
  public_subnets  = [for i, _ in var.availability_zones : cidrsubnet(var.vpc_cidr, 8, 64 + i)]
}

# ─── Network ──────────────────────────────────────────────────────────────────
# Two zones: the API server and the load balancer need two, and a node group spreads over both. The
# subnet tags tell the Load Balancer Controller where an internet-facing (public) or internal (private)
# load balancer goes.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = var.availability_zones

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # One NAT gateway: the nodes' only way out (images from GHCR, Helm charts, Let's Encrypt, Cloudflare,
  # GitHub for Flux). Paid per hour and per GB. var.single_nat_gateway = false puts one in each zone,
  # so a zone outage does not cut the other zone off.
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }

  # VPC Flow Logs (var.flow_logs): every accepted and rejected connection of the VPC, to CloudWatch Logs,
  # through the foundation's role (this module creates no IAM role). AWS's default record format.
  enable_flow_log                                 = var.flow_logs
  flow_log_destination_type                       = "cloud-watch-logs"
  create_flow_log_cloudwatch_log_group            = var.flow_logs
  create_flow_log_cloudwatch_iam_role             = false
  flow_log_cloudwatch_iam_role_arn                = var.flow_logs ? data.aws_iam_role.vpc_flow_logs[0].arn : ""
  flow_log_cloudwatch_log_group_name_prefix       = "/aws/vpc-flow-log/"
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_max_aggregation_interval               = 60

  depends_on = [data.aws_caller_identity.me]
}

# S3 through the VPC, not through the NAT gateway: ECR image layers come from S3, and a gateway endpoint
# is free where the NAT gateway charges per GB.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}

# ─── Cluster ──────────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version
  # Standard support only: extended support starts by itself when a version's standard support ends
  # and costs six times as much ($0.60 an hour instead of $0.10). A cluster on an expired version is
  # upgraded by AWS instead - plan upgrades before that date.
  upgrade_policy = { support_type = "STANDARD" }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public endpoint for kubectl and Terraform (IAM decides), private endpoint for the nodes: their
  # traffic to the API server stays in the VPC.
  endpoint_public_access       = true
  endpoint_private_access      = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # Access entries only (no aws-auth ConfigMap). Whoever creates the cluster - the identity check above
  # makes that var.expected_principal_arn - gets cluster admin; nobody else has access.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # The foundation's roles; no IRSA OIDC provider (Pod Identity); no KMS key - EKS encrypts all Kubernetes
  # API data, Secrets included, with an AWS-owned key, and a key of our own would be billed and left
  # PendingDeletion by every cycle.
  create_iam_role   = false
  iam_role_arn      = data.aws_iam_role.cluster.arn
  create_kms_key    = false
  encryption_config = null
  enable_irsa       = false

  # Control-plane logs to CloudWatch Logs (var.control_plane_log_types); no log group without them.
  enabled_log_types                      = var.control_plane_log_types
  create_cloudwatch_log_group            = length(var.control_plane_log_types) > 0
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  # The VPC CNI and the Pod Identity agent before the nodes: a node that joins without a CNI never gets
  # Ready, and the EBS CSI driver needs the agent for its credentials.
  addons = {
    vpc-cni = {
      before_compute = true
      # NetworkPolicy (the platform's default-deny, egress too) and prefix delegation: a /28 per ENI slot
      # instead of one address, so the node's network interfaces do not cap its pods (an m7i.large: 29
      # pods without it). Set before the nodes exist: EKS sizes a node's pod limit when it creates it.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    coredns    = {}
    kube-proxy = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = data.aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
    # The metrics API (kubectl top, HorizontalPodAutoscaler): GKE and k3s have it built in, EKS as an add-on.
    metrics-server = {}
  }

  eks_managed_node_groups = {
    platform = merge(local.node_group, {
      instance_types = var.platform_pool.instance_types
      capacity_type  = var.platform_pool.spot ? "SPOT" : "ON_DEMAND"
      min_size       = var.platform_pool.node_count
      max_size       = var.platform_pool.node_count
      desired_size   = var.platform_pool.node_count
      labels         = { pool = "platform" }
      block_device_mappings = {
        xvda = merge(local.root_disk, { ebs = merge(local.root_disk.ebs, { volume_size = var.platform_pool.disk_size_gb }) })
      }
    })
    apps = merge(local.node_group, {
      instance_types = var.apps_pool.instance_types
      capacity_type  = var.apps_pool.spot ? "SPOT" : "ON_DEMAND"
      min_size       = var.apps_pool.node_count
      max_size       = var.apps_pool.node_count
      desired_size   = var.apps_pool.node_count
      labels         = { pool = "apps" }
      block_device_mappings = {
        xvda = merge(local.root_disk, { ebs = merge(local.root_disk.ebs, { volume_size = var.apps_pool.disk_size_gb }) })
      }
    })
  }
}

# Node settings both groups share. A fixed size: EKS adds no nodes by itself - that takes a cluster
# autoscaler or Karpenter, neither of which runs here. A pool grows by its node_count in terraform.tfvars.
locals {
  node_group = {
    ami_type        = "AL2023_x86_64_STANDARD"
    create_iam_role = false
    iam_role_arn    = data.aws_iam_role.nodes.arn
    # IMDSv2 only, and the token does not travel past the node (hop limit 1): a pod cannot read the
    # node role's credentials. The add-ons that need AWS get them through Pod Identity.
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 1
    }
    # An update starts new nodes before it drains the old ones, one node at a time.
    update_config = { max_unavailable = 1 }
  }

  # The root disk: gp3, encrypted (also the account default), deleted with the node.
  root_disk = {
    device_name = "/dev/xvda"
    ebs = {
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
}

# ─── AWS Load Balancer Controller ─────────────────────────────────────────────
# Gives Traefik's LoadBalancer Service a Network Load Balancer (profiles/eks sets its class and
# annotations). Installed here, before Flux, so the Service finds it when Flux creates it - and removed
# after the pre-destroy hook (flux.tf), so it can still delete the NLB with the Service.
# Credentials: the foundation's role through Pod Identity. region and vpcId are given: with IMDS hop
# limit 1 the controller cannot read them from the node.
resource "aws_eks_pod_identity_association" "aws_lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = data.aws_iam_role.aws_lbc.arn
}

resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_lbc_chart_version

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    region      = var.region
    vpcId       = module.vpc.vpc_id
    serviceAccount = {
      name = "aws-load-balancer-controller"
    }
    # Off: the webhook would hand EVERY LoadBalancer Service to this controller. The profile names the
    # class on Traefik's Service itself - explicit, and visible in Git.
    enableServiceMutatorWebhook = false
  })]

  depends_on = [
    aws_eks_pod_identity_association.aws_lbc,
    module.eks,
  ]
}

# ─── kubeconfig ───────────────────────────────────────────────────────────────
# The endpoint and `aws eks get-token` of the profile: kubectl asks the AWS CLI for a short-lived token
# of whoever is signed in. The file holds no credentials. The context name is fixed, so tools can name it.
resource "local_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig.yaml"
  file_permission = "0600"
  content = yamlencode({
    apiVersion        = "v1"
    kind              = "Config"
    "current-context" = "eks-${var.cluster_name}-control-plane"
    clusters = [{
      name = "eks-${var.cluster_name}"
      cluster = {
        server                       = module.eks.cluster_endpoint
        "certificate-authority-data" = module.eks.cluster_certificate_authority_data
      }
    }]
    users = [{
      name = "eks-${var.cluster_name}"
      user = {
        exec = {
          apiVersion  = local.eks_exec.api_version
          command     = local.eks_exec.command
          args        = local.eks_exec.args
          installHint = "AWS CLI 2.32 or newer, signed in: aws login --profile ${var.aws_profile} (docs/aws.md)"
        }
      }
    }]
    contexts = [{
      name    = "eks-${var.cluster_name}-control-plane"
      context = { cluster = "eks-${var.cluster_name}", user = "eks-${var.cluster_name}" }
    }]
  })
}

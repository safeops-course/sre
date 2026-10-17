# What the EKS workflow and the cluster module need from the foundation. None of it is secret: a role ARN
# only works together with credentials the trust policy accepts.

output "deployer_role_arn" {
  description = "For aws-actions/configure-aws-credentials: role-to-assume (the identity the EKS workflow runs as)."
  value       = aws_iam_role.deployer.arn
}

output "eks_cluster_role_arn" {
  description = "The EKS control plane role (cluster module: iam_role_arn)."
  value       = aws_iam_role.eks_cluster.arn
}

output "eks_nodes_role_arn" {
  description = "The role of every managed node group (cluster module: node group iam_role_arn)."
  value       = aws_iam_role.eks_nodes.arn
}

output "ebs_csi_role_arn" {
  description = "The EBS CSI driver's Pod Identity role."
  value       = module.ebs_csi_role.iam_role_arn
}

output "aws_lbc_role_arn" {
  description = "The AWS Load Balancer Controller's Pod Identity role."
  value       = module.aws_lbc_role.iam_role_arn
}

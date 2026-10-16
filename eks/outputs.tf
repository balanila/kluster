output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "node_autoscaling_group_name" {
  value = aws_eks_node_group.this.resources[0].autoscaling_groups[0].name
}

output "autoscaler_role_arn" {
  value = aws_iam_role.autoscaler.arn
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name} --alias ${var.cluster_name}"
}

output "addons_tfvars" {
  description = "Несекретные параметры второго Terraform-этапа."
  value = {
    aws_region           = var.aws_region
    cluster_name         = aws_eks_cluster.this.name
    postgres_storage_gib = var.postgres_storage_gib
  }
}

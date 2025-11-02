output "cluster_id" {
  value = aws_eks_cluster.eks.id
}

output "node_group_id" {
  value = aws_eks_node_group.eks.id
}

output "vpc_id" {
  value = aws_vpc.eks_vpc.id
}

output "subnet_ids" {
  value = aws_subnet.eks_subnet[*].id
}

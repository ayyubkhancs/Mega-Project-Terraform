terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

#################################################
# VPC + Subnets
#################################################
resource "aws_vpc" "eks_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "eks-vpc"
  }
}

resource "aws_subnet" "eks_subnet" {
  count = 2
  vpc_id                  = aws_vpc.eks_vpc.id
  # keep as you had (cidrsubnet) or list explicit CIDRs
  cidr_block              = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)
  availability_zone       = element(["us-east-1a", "us-east-1b"], count.index)
  map_public_ip_on_launch = true

  tags = {
    Name                     = "eks-subnet-${count.index}"
    "kubernetes.io/role/elb" = "1"   # recommended tag for public subnets used by LoadBalancers
  }
}

resource "aws_internet_gateway" "eks_igw" {
  vpc_id = aws_vpc.eks_vpc.id

  tags = {
    Name = "eks-igw"
  }
}

resource "aws_route_table" "eks_route_table" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eks_igw.id
  }

  tags = {
    Name = "eks-route-table"
  }
}

resource "aws_route_table_association" "eks_association" {
  count          = 2
  subnet_id      = aws_subnet.eks_subnet[count.index].id
  route_table_id = aws_route_table.eks_route_table.id
}

#################################################
# Security Groups (testing: wide open; tighten for prod)
#################################################
resource "aws_security_group" "eks_cluster_sg" {
  vpc_id = aws_vpc.eks_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-cluster-sg"
  }
}

resource "aws_security_group" "eks_node_sg" {
  vpc_id = aws_vpc.eks_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-node-sg"
  }
}

#################################################
# IAM: EKS cluster role (+ required policies)
#################################################
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "eks_cluster_role_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Add service policy which the cluster also needs
resource "aws_iam_role_policy_attachment" "eks_cluster_service_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
}

#################################################
# EKS cluster
#################################################
resource "aws_eks_cluster" "eks" {
  name     = "eks-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids         = aws_subnet.eks_subnet[*].id
    security_group_ids = [aws_security_group.eks_cluster_sg.id]
  }

  # ensure cluster is fully created after role attachments
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_role_policy,
    aws_iam_role_policy_attachment.eks_cluster_service_policy
  ]
}

#################################################
# OIDC provider for IRSA (required for addons like aws-ebs-csi-driver)
#################################################
data "aws_eks_cluster" "eks" {
  name = aws_eks_cluster.eks.name
  depends_on = [aws_eks_cluster.eks]
}

# Use aws_eks_cluster.identity[0].oidc[0].issuer to create the provider
resource "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.eks.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  # This thumbprint is commonly used for EKS OIDC; if your provider requires different value, adjust.
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da0afd10f54"]
}

#################################################
# Node Group IAM role + attachments
#################################################
resource "aws_iam_role" "eks_node_group_role" {
  name = "eks-node-group-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "eks_node_group_role_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_group_cni_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_node_group_registry_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_node_group_ebs_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

#################################################
# EKS addon: aws-ebs-csi-driver
# depends_on ensures OIDC provider exists before creating addon
#################################################
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name    = aws_eks_cluster.eks.name
  addon_name      = "aws-ebs-csi-driver"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_iam_openid_connect_provider.eks,
    aws_eks_cluster.eks
  ]
}

#################################################
# Managed Node Group
#################################################
resource "aws_eks_node_group" "eks" {
  cluster_name    = aws_eks_cluster.eks.name
  node_group_name = "eks-node-group"
  node_role_arn   = aws_iam_role.eks_node_group_role.arn
  subnet_ids      = aws_subnet.eks_subnet[*].id

  scaling_config {
    desired_size = 3
    max_size     = 3
    min_size     = 3
  }

  # NOTE: if "c7i-flex.large" fails in your account/AMI, you can use a standard instance type
  # like "c7i.large" or "m6i.large" depending on availability in your region/account.
  instance_types = ["c7i-flex.large"]

  remote_access {
    ec2_ssh_key              = var.ssh_key_name
    source_security_group_ids = [aws_security_group.eks_node_sg.id]
  }

  depends_on = [
    aws_eks_cluster.eks,
    aws_iam_role_policy_attachment.eks_node_group_role_policy,
    aws_iam_role_policy_attachment.eks_node_group_cni_policy,
    aws_iam_role_policy_attachment.eks_node_group_registry_policy,
    aws_iam_role_policy_attachment.eks_node_group_ebs_policy
  ]
}

terraform {
  required_version = ">= 1.6.0, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.21"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "cluster_name" {
  type    = string
  default = "ytd-eks"
}

provider "aws" {
  region = var.aws_region
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_iam_role" "autoscaler" {
  name = "${var.cluster_name}-autoscaler"
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
    }
  }
}

resource "helm_release" "autoscaler" {
  name       = "cluster-autoscaler"
  namespace  = "kube-system"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.54.0"
  atomic     = true
  timeout    = 600

  values = [yamlencode({
    fullnameOverride = "cluster-autoscaler"
    cloudProvider    = "aws"
    awsRegion        = var.aws_region
    autoDiscovery    = { clusterName = var.cluster_name }
    image            = { tag = "v1.35.0" }
    rbac = {
      serviceAccount = {
        name = "cluster-autoscaler"
        annotations = {
          "eks.amazonaws.com/role-arn" = data.aws_iam_role.autoscaler.arn
        }
      }
    }
    extraArgs = {
      "balance-similar-node-groups" = "true"
      "skip-nodes-with-system-pods" = "false"
    }
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "300m", memory = "300Mi" }
    }
  })]

  lifecycle {
    precondition {
      condition     = data.aws_eks_cluster.this.version == "1.35"
      error_message = "Этот chart/image закреплён для Kubernetes 1.35. При смене EKS обнови согласованно chart и image autoscaler."
    }
  }
}

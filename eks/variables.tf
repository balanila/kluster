variable "aws_region" {
  description = "Регион AWS."
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "Имя отдельного EKS-кластера."
  type        = string
  default     = "ytd-eks"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,39}$", var.cluster_name))
    error_message = "Используй до 40 латинских букв, цифр и дефисов, начиная с буквы."
  }
}

variable "kubernetes_version" {
  description = "Minor-версия EKS; при изменении согласуй версию Cluster Autoscaler."
  type        = string
  default     = "1.35"
}

variable "cluster_admin_arn" {
  description = "IAM role/user ARN администратора Kubernetes, не STS assumed-role session ARN."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/.+$", var.cluster_admin_arn))
    error_message = "Укажи IAM ARN роли или пользователя AWS, не ARN сессии STS."
  }
}

variable "api_allowed_cidrs" {
  description = "Публичные IPv4 CIDR для доступа к Kubernetes API, обычно IP администратора /32."
  type        = list(string)

  validation {
    condition = length(var.api_allowed_cidrs) > 0 && alltrue([
      for cidr in var.api_allowed_cidrs : can(cidrnetmask(cidr)) && !endswith(cidr, "/0")
    ])
    error_message = "Укажи хотя бы один IPv4 CIDR; открывать API на /0 нельзя."
  }
}

variable "vpc_cidr" {
  description = "Отдельная IPv4 сеть /16; публичные подсети /24 вычисляются из неё."
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && endswith(var.vpc_cidr, "/16")
    error_message = "Укажи IPv4 CIDR с маской /16."
  }
}

variable "node_instance_type" {
  description = "t3.micro = 2 vCPU / 1 GiB. Только x86_64, согласно выбранному AMI."
  type        = string
  default     = "t3.micro"

  validation {
    condition     = contains(["t3.micro", "t3a.micro", "t3.small", "t3a.small", "t3.medium", "t3a.medium"], var.node_instance_type)
    error_message = "Выбери поддерживаемый x86_64 t3/t3a micro, small или medium."
  }
}

variable "postgres_storage_gib" {
  description = "Размер отдельного gp3-диска PostgreSQL в GiB. Передаётся во второй Terraform-этап."
  type        = number
  default     = 5

  validation {
    condition     = var.postgres_storage_gib >= 5 && floor(var.postgres_storage_gib) == var.postgres_storage_gib
    error_message = "Размер PostgreSQL-диска должен быть целым числом не меньше 5 GiB."
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
  }
}

variable "postgres_storage_gib" {
  description = "Размер PVC PostgreSQL. Можно только увеличивать без пересоздания диска."
  type        = number
  default     = 5

  validation {
    condition     = var.postgres_storage_gib >= 5 && floor(var.postgres_storage_gib) == var.postgres_storage_gib
    error_message = "Укажи целый размер диска не меньше 5 GiB."
  }
}

data "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"
}

resource "helm_release" "ebs_csi" {
  name       = "aws-ebs-csi-driver"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  chart      = "aws-ebs-csi-driver"
  version    = "2.67.0"
  atomic     = true
  timeout    = 900

  values = [yamlencode({
    controller = {
      replicaCount = 1
      region       = var.aws_region
      serviceAccount = {
        name = "ebs-csi-controller-sa"
        annotations = {
          "eks.amazonaws.com/role-arn" = data.aws_iam_role.ebs_csi.arn
        }
      }
    }
    node = {
      # Сохраняем два Pod IP micro-ноды для обычных Pod.
      hostNetwork   = true
      enableWindows = false
    }
  })]

  # На маленьких нодах драйвер может потребовать третью ноду: сначала CA.
  depends_on = [helm_release.autoscaler]
}

resource "kubernetes_namespace_v1" "apps" {
  metadata {
    name = "ytd"
  }
}

resource "kubernetes_storage_class_v1" "postgres" {
  metadata {
    name = "postgres-gp3"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type                        = "gp3"
    encrypted                   = "true"
    "csi.storage.k8s.io/fstype" = "ext4"
  }
}

resource "random_password" "postgres_admin" {
  length  = 32
  special = false
}

resource "random_password" "shoplist" {
  length  = 32
  special = false
}

# Значения не выводятся в outputs, но присутствуют в Terraform state.
resource "kubernetes_secret_v1" "postgres" {
  metadata {
    name      = "postgres-credentials"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
  data = {
    POSTGRES_USER     = "postgres"
    POSTGRES_DB       = "shoplist"
    POSTGRES_PASSWORD = random_password.postgres_admin.result
    SHOPLIST_PASSWORD = random_password.shoplist.result
  }
}

resource "kubernetes_secret_v1" "shoplist" {
  metadata {
    name      = "shoplist-credentials"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
  data = {
    POSTGRES_USER     = "shoplist"
    POSTGRES_PASSWORD = random_password.shoplist.result
  }
}

resource "kubernetes_config_map_v1" "postgres_init" {
  metadata {
    name      = "postgres-init"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
  data = {
    "01-shoplist.sh" = <<-SCRIPT
      #!/bin/sh
      set -eu
      psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        --set=ON_ERROR_STOP=1 --set=app_password="$SHOPLIST_PASSWORD" <<'SQL'
      CREATE ROLE shoplist LOGIN PASSWORD :'app_password';
      ALTER DATABASE shoplist OWNER TO shoplist;
      CREATE SCHEMA IF NOT EXISTS shoplist AUTHORIZATION shoplist;
      SQL
    SCRIPT
  }
}

resource "kubernetes_persistent_volume_claim_v1" "postgres" {
  metadata {
    name      = "postgres-data"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.postgres.metadata[0].name
    resources {
      requests = { storage = "${var.postgres_storage_gib}Gi" }
    }
  }
  # WFFC: диск создаётся после выбора ноды для StatefulSet.
  wait_until_bound = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_service_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
  spec {
    cluster_ip = "None"
    selector   = { app = "postgres" }
    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_stateful_set_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
  spec {
    service_name = kubernetes_service_v1.postgres.metadata[0].name
    replicas     = 1
    selector {
      match_labels = { app = "postgres" }
    }
    template {
      metadata {
        labels = { app = "postgres" }
        annotations = {
          "cluster-autoscaler.kubernetes.io/safe-to-evict" = "false"
        }
      }
      spec {
        termination_grace_period_seconds = 60
        automount_service_account_token  = false
        container {
          name  = "postgres"
          image = "postgres:17.11-bookworm"
          args = [
            "-c", "shared_buffers=32MB",
            "-c", "max_connections=20",
            "-c", "work_mem=1MB",
            "-c", "maintenance_work_mem=16MB",
          ]
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.postgres.metadata[0].name
            }
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          port {
            name           = "postgres"
            container_port = 5432
          }
          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "384Mi" }
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
          volume_mount {
            name       = "init"
            mount_path = "/docker-entrypoint-initdb.d"
            read_only  = true
          }
          startup_probe {
            exec {
              command = ["pg_isready", "-U", "postgres", "-d", "shoplist", "-h", "127.0.0.1"]
            }
            period_seconds    = 5
            failure_threshold = 60
          }
          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "postgres", "-d", "shoplist", "-h", "127.0.0.1"]
            }
            period_seconds = 10
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.postgres.metadata[0].name
          }
        }
        volume {
          name = "init"
          config_map {
            name = kubernetes_config_map_v1.postgres_init.metadata[0].name
          }
        }
      }
    }
  }

  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [helm_release.ebs_csi]
}

output "postgres_host" {
  value = "postgres.ytd.svc.cluster.local"
}

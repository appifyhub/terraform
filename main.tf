# Terraform language documentation: https://www.terraform.io/docs/language/index.html
# HCL language specification: https://github.com/hashicorp/hcl/blob/main/hclsyntax/spec.md
# Module documentation: https://registry.terraform.io/modules/identiops/k3s/hcloud/latest
# Copyright 2024, identinet GmbH. All rights reserved.
# SPDX-License-Identifier: MIT

###########################
#    I M P O R T A N T    #
###########################

# Go to `cluster_init_action` in this file to enable/disable init depending
# on whether this is the first `tf apply` run or a subsequent one.

###########################
#  Backend and Providers  #
###########################

terraform {
  # See Version Constraints: https://developer.hashicorp.com/terraform/language/expressions/version-constraints
  backend "local" {
    path = "terraform.tfstate"
  }
  # Example s3 configuration (not needed yet):
  # backend "s3" {
  #   bucket = "xxxxx-terraform"
  #   key    = "prod/terraform.tfstate"
  #   # access_key                  = {}
  #   # secret_key                  = {}
  #   # skip_get_ec2_platforms      = true
  #   region                      = "eu-central-2"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   skip_requesting_account_id  = true
  #   skip_s3_checksum            = true
  #   use_path_style              = true
  #   endpoints = {
  #     iam = "https://iam.eu-central-2.wasabisys.com" # special endpoint URL required, see https://wasabi-support.zendesk.com/hc/en-us/articles/360003362071-How-do-I-use-Terraform-with-Wasabi-
  #     sts = "https://sts.eu-central-2.wasabisys.com" # special endpoint URL required, see https://wasabi-support.zendesk.com/hc/en-us/articles/360003362071-How-do-I-use-Terraform-with-Wasabi-
  #     s3  = "https://s3.eu-central-2.wasabisys.com"  # special endpoint URL required, see https://wasabi-support.zendesk.com/hc/en-us/articles/360003362071-How-do-I-use-Terraform-with-Wasabi-
  #   }
  # }
  required_version = "~> 1.0"
}

###########################
#  Cluster configuration  #
###########################

module "cluster" {
  # source               = "github.com/identiops/terraform-hcloud-k3s?ref=6.1.0"
  source                 = "identiops/k3s/hcloud"
  version                = "6.1.2"
  hcloud_token           = var.hcloud_token           # Set via `export TF_VAR_hcloud_token=xyz` or in .tfvars
  hcloud_token_read_only = var.hcloud_token_read_only # Set via `export TF_VAR_hcloud_token_read_only=abc` or in .tfvars

  # Cluster Settings
  # ----------------
  delete_protection = true # Must be set to false + `terraform apply` before destroying the cluster via `terraform destroy`!
  cluster_name      = "ah"
  default_location  = "fsn1"         # See all: https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs/resources/server#location
  default_image     = "ubuntu-24.04" # See all: `curl -H \"Authorization: Bearer $HETZNER_API_TOKEN_READONLY\" https://api.hetzner.cloud/v1/images | jq -r '.images[].name' | sort`
  k3s_version       = "v1.32.2+k3s1" # See all: https://update.k3s.io/v1-release/channels; Regular images: https://hub.docker.com/r/rancher/k3s/tags; Upgrade images: https://hub.docker.com/r/rancher/k3s-upgrade/tags

  # General Settings
  # ----------------
  # Root access to all systems
  ssh_keys = {
    "admin" = file("~/.ssh/id_rsa.pub")
  }

  # Just kubeapi access via port-forwarding
  ssh_keys_kubeapi = {
    "admin" = file("~/.ssh/id_rsa.pub")
  }

  # Gateway Settings
  # ----------------------
  gateway_firewall_k8s_open = true   # Open kubeapi port to the internet
  gateway_server_type       = "cx22" # See all: https://docs.hetzner.com/cloud/servers/overview#shared-vcpu
  gateway_labels = {
    "gateway" = "yes"
  }

  # Control Plane Settings
  # ----------------------
  # Example s3 configuration (not needed yet):
  # S3 documentation  https://docs.k3s.io/cli/server
  # control_plane_k3s_init_additional_options = "--etcd-s3 --etcd-s3-region=${var.etcd_s3_region} --etcd-s3-endpoint=s3.${var.etcd_s3_region}.wasabisys.com --etcd-s3-access-key=${var.etcd_s3_access_key} --etcd-s3-secret-key=${var.etcd_s3_secret_key} --etcd-s3-bucket=${var.etcd_s3_bucket} --etcd-s3-folder=etcd/$(hostname)"
  # ETCD tuning documentation for multi-region deployment (not needed yet): https://etcd.io/docs/v3.4/tuning/#time-parameters
  # control_plane_k3s_additional_options      = "--etcd-arg=heartbeat-interval=120 --etcd-arg=election-timeout=1200" # See https://etcd.io/docs/v3.4/tuning/#time-parameters
  additional_cloud_init = {
    timezone = "Europe/Berlin" # See all: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones#List
  }

  # Node Group Settings
  # -------------------
  # Map of worker node groups, key is server_type, value is count of nodes in group
  node_pools = {
    system = {
      cluster_can_init = true # Required for one node pool to perform initializing actions.
      cluster_init_action = {
        # `init` must be `true` for the first run of `terraform apply`.
        # For later runs it should be set to `false` to prevent any accidential
        # reinitialization of the cluster, e.g. when the first node of this pool
        # is manually deleted via the management console.
        init = false,
      }
      is_control_plane   = true
      schedule_workloads = true   # Disable if you want to use this node pool for control plane only
      type               = "cx22" # See all: https://docs.hetzner.com/cloud/servers/overview#shared-vcpu
      count              = 1      # Should be an odd number for etcd quorum
      count_width        = 2
      labels = {
        "control-plane" = "yes"
      }
      taints = {
        # "MyTaint=true" = "NoSchedule"
      }
    }
    workers = {
      is_control_plane   = false
      schedule_workloads = true
      type               = "cx22" # See all: https://docs.hetzner.com/cloud/servers/overview#shared-vcpu
      count              = 1
      count_width        = 2
      labels = {
        "worker-node" = "yes"
      }
      taints = {}
    }
  }
}


###############
#  Variables  #
###############

variable "hcloud_token" {
  description = "Hetzner cloud auth token."
  type        = string
  sensitive   = true
}

variable "hcloud_token_read_only" {
  description = "Hetzner cloud auth token, read only - used by the gateway and all cluster servers to proxy kubernetes traffic to control plane nodes."
  type        = string
  sensitive   = true
}

# Example s3 configuraiton (not needed yet):
# variable "etcd_s3_region" {
#   type      = string
#   sensitive = true
# }
# 
# variable "etcd_s3_access_key" {
#   type      = string
#   sensitive = true
# }
# 
# variable "etcd_s3_secret_key" {
#   type      = string
#   sensitive = true
# }
# 
# variable "etcd_s3_bucket" {
#   type      = string
#   sensitive = true
# }

############
#  Output  #
############

output "gateway" {
  depends_on  = [module.cluster]
  description = "IP Addresses of the gateway."
  value       = module.cluster.gateway
}

output "node_pools" {
  depends_on  = [module.cluster]
  description = "IP Addresses of the worker node pools."
  value       = module.cluster.node_pools
}

output "total_monthly_costs" {
  depends_on  = [module.cluster]
  description = "Total monthly costs for running the cluster."
  value       = module.cluster.total_monthly_costs
}

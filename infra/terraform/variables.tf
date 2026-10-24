variable "region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zone" {
  type    = string
  default = "us-east-1a"
}

variable "cluster_name" {
  type    = string
  default = "monitoring-poc"
}

variable "rke2_version" {
  type    = string
  default = "v1.37.1+rke2r1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

# Open to the internet by request; narrow to your own /32 when possible.
variable "allowed_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/monitoring-poc-ed25519.pub"
}

variable "control_plane_count" {
  type    = number
  default = 3
}

variable "worker_count" {
  type    = number
  default = 3
}

# This account is on the AWS free plan, which only allows free-tier-eligible instance types.
variable "control_plane_instance_type" {
  type    = string
  default = "c7i-flex.large"
}

variable "worker_instance_type" {
  type    = string
  default = "m7i-flex.large"
}

variable "control_plane_volume_gb" {
  type    = number
  default = 40
}

variable "worker_volume_gb" {
  type    = number
  default = 60
}

variable "enable_kube_vip" {
  type    = bool
  default = true
}

# A VIP inside the subnet; kube-vip ARP cannot make it reachable in a VPC, the NLB is the real endpoint.
variable "kube_vip_address" {
  type    = string
  default = "10.0.1.250"
}

variable "kube_vip_image" {
  type    = string
  default = "ghcr.io/kube-vip/kube-vip:v1.3.1"
}

variable "aws_ccm_chart_version" {
  type    = string
  default = "0.0.12"
}

variable "aws_ccm_image_tag" {
  type    = string
  default = "v1.37.0"
}

variable "argocd_chart_version" {
  type    = string
  default = "10.11.1"
}

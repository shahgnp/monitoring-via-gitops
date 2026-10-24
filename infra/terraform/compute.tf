data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "random_password" "rke2_token" {
  length  = 40
  special = false
}

locals {
  nlb_dns = aws_lb.api.dns_name

  kube_vip_manifest = templatefile("${path.module}/templates/kube-vip.yaml.tftpl", {
    image   = var.kube_vip_image
    address = var.kube_vip_address
  })

  aws_ccm_manifest = templatefile("${path.module}/templates/manifests/aws-ccm.yaml.tftpl", {
    chart_version = var.aws_ccm_chart_version
    image_tag     = var.aws_ccm_image_tag
    cluster_name  = var.cluster_name
  })

  argocd_manifest = templatefile("${path.module}/templates/manifests/argocd.yaml.tftpl", {
    chart_version = var.argocd_chart_version
  })

  server_vars = {
    rke2_version      = var.rke2_version
    token             = random_password.rke2_token.result
    nlb_dns           = local.nlb_dns
    kube_vip_address  = var.kube_vip_address
    enable_kube_vip   = var.enable_kube_vip
    kube_vip_manifest = local.kube_vip_manifest
    aws_ccm_manifest  = local.aws_ccm_manifest
    argocd_manifest   = local.argocd_manifest
  }
}

resource "aws_instance" "control_plane" {
  count                       = var.control_plane_count
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.control_plane_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes.id]
  key_name                    = aws_key_pair.this.key_name
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = true

  user_data = templatefile(
    "${path.module}/templates/server.sh.tftpl",
    merge(local.server_vars, { first = count.index == 0 })
  )

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.control_plane_volume_gb
  }

  tags = {
    Name                                        = "${var.cluster_name}-cp-${count.index}"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    Role                                        = "control-plane"
  }
}

resource "aws_instance" "worker" {
  count                       = var.worker_count
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.worker_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes.id]
  key_name                    = aws_key_pair.this.key_name
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/agent.sh.tftpl", {
    rke2_version = var.rke2_version
    token        = random_password.rke2_token.result
    nlb_dns      = local.nlb_dns
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.worker_volume_gb
  }

  tags = {
    Name                                        = "${var.cluster_name}-worker-${count.index}"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    Role                                        = "worker"
  }
}

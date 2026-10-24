# Rules are separate resources because the AWS cloud controller adds its own rules to this group.
resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes"
  description = "RKE2 nodes"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name                                        = "${var.cluster_name}-nodes"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

resource "aws_vpc_security_group_ingress_rule" "self" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  description                  = "Node to node"
}

resource "aws_vpc_security_group_ingress_rule" "vpc_api" {
  for_each          = toset(["6443", "9345"])
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  description       = "API and join traffic via the NLB"
}

resource "aws_vpc_security_group_ingress_rule" "external" {
  for_each          = toset(["22", "6443"])
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.allowed_cidr
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  description       = "External access"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

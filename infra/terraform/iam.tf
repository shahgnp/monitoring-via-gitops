data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Permissions for the AWS cloud controller manager (load balancers, node lookup).
data "aws_iam_policy_document" "ccm" {
  statement {
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeImages",
      "ec2:DescribeRegions",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVolumes",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeVpcs",
      "ec2:DescribeInstanceTopology",
      "ec2:CreateSecurityGroup",
      "ec2:CreateTags",
      "ec2:ModifyInstanceAttribute",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "elasticloadbalancing:*",
      "iam:CreateServiceLinkedRole",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "ccm" {
  name   = "cloud-controller-manager"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.ccm.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-node"
  role = aws_iam_role.node.name
}

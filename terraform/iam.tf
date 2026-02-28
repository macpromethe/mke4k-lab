data "aws_iam_policy_document" "mke4k_ccm_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mke4k_ccm" {
  count              = var.ccm_enabled ? 1 : 0
  name               = "${var.cluster_name}-ccm-role"
  assume_role_policy = data.aws_iam_policy_document.mke4k_ccm_assume_role.json

  tags = {
    Name    = "${var.cluster_name}-ccm-role"
    Cluster = var.cluster_name
  }
}

data "aws_iam_policy_document" "mke4k_ccm_policy" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumesModifications",
      "ec2:DescribeVpcs",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeTags",
      "ec2:CreateSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:AttachVolume",
      "ec2:DetachVolume",
      "ec2:CreateVolume",
      "ec2:DeleteVolume",
      "ec2:ModifyVolume",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer",
      "elasticloadbalancing:AttachLoadBalancerToSubnets",
      "elasticloadbalancing:ConfigureHealthCheck",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateLoadBalancerListeners",
      "elasticloadbalancing:CreateLoadBalancerPolicy",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DeleteLoadBalancerListeners",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeLoadBalancerPolicies",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DetachLoadBalancerFromSubnets",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:RemoveTags",
      "elasticloadbalancing:SetLoadBalancerPoliciesForBackendServer",
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "mke4k_ccm" {
  count  = var.ccm_enabled ? 1 : 0
  name   = "${var.cluster_name}-ccm-policy"
  policy = data.aws_iam_policy_document.mke4k_ccm_policy.json

  tags = {
    Cluster = var.cluster_name
  }
}

resource "aws_iam_role_policy_attachment" "mke4k_ccm" {
  count      = var.ccm_enabled ? 1 : 0
  role       = aws_iam_role.mke4k_ccm[0].name
  policy_arn = aws_iam_policy.mke4k_ccm[0].arn
}

resource "aws_iam_instance_profile" "mke4k_ccm" {
  count = var.ccm_enabled ? 1 : 0
  name  = "${var.cluster_name}-ccm-profile"
  role  = aws_iam_role.mke4k_ccm[0].name

  tags = {
    Cluster = var.cluster_name
  }
}

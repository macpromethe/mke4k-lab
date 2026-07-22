# ---------------------------------------------------------------------------
# Auto-expiry reaper
#
# When expiry_days > 0, Terraform provisions a self-contained teardown:
#
#   time_offset.expiry ── (base + expiry_days) ─────────┐
#                                                        ▼
#   aws_scheduler_schedule.expiry  ── one-shot at() ──> aws_lambda_function.reaper
#     (reaper deletes the schedule when it self-cleans)    (reaper.py, boto3)
#
# At expiry the Lambda deletes every object tagged Cluster=<cluster_name>
# (EC2, NLBs/target groups, VPC + deps, CCM IAM, key pair) and then its own
# scaffolding. 't destroy lab' runs `terraform destroy`, which deletes the
# schedule/Lambda/roles first — so the reaper only ever fires on labs that
# were left running past their expiry. Runs entirely inside AWS, so it works
# even if the operator's machine/container is switched off.
#
# Everything here is gated on expiry_days > 0 (0 = never expire).
# ---------------------------------------------------------------------------

locals {
  expiry_enabled = var.expiry_days > 0
}

# The expiry moment = base + expiry_days. base defaults to this resource's
# creation time (stable across later applies); 't expiry <N>' rebases it to
# "now" via var.expiry_base so the deadline becomes now + N.
resource "time_offset" "expiry" {
  count        = local.expiry_enabled ? 1 : 0
  base_rfc3339 = var.expiry_base != "" ? var.expiry_base : null
  offset_days  = var.expiry_days
}

# ---- Reaper Lambda ---------------------------------------------------------
data "archive_file" "reaper" {
  count       = local.expiry_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/reaper.py"
  output_path = "${path.module}/reaper.zip"
}

data "aws_iam_policy_document" "reaper_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Teardown permissions. Action-scoped with Resource="*" — most of these delete
# calls (delete-subnet, delete-vpc, …) do not support resource/tag conditions,
# and the reaper is a short-lived, self-deleting function that only ever acts on
# this lab's own resources. Acceptable for a lab tool; do not copy into prod.
data "aws_iam_policy_document" "reaper" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:TerminateInstances",
      "ec2:DeleteKeyPair",
      "ec2:DeleteSecurityGroup",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:DeleteSubnet",
      "ec2:DeleteRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:DetachInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:DeleteVpc",
      "elasticloadbalancing:Describe*",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DeleteTargetGroup",
      "iam:GetRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:DeleteRole",
      "iam:DeletePolicy",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile",
      "sts:GetCallerIdentity",
      "scheduler:DeleteSchedule",
      "lambda:DeleteFunction",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "reaper" {
  count              = local.expiry_enabled ? 1 : 0
  name               = "${var.cluster_name}-reaper-role"
  assume_role_policy = data.aws_iam_policy_document.reaper_assume.json

  tags = {
    Name    = "${var.cluster_name}-reaper-role"
    Cluster = var.cluster_name
  }
}

resource "aws_iam_role_policy" "reaper" {
  count  = local.expiry_enabled ? 1 : 0
  name   = "${var.cluster_name}-reaper-policy"
  role   = aws_iam_role.reaper[0].id
  policy = data.aws_iam_policy_document.reaper.json
}

resource "aws_lambda_function" "reaper" {
  count            = local.expiry_enabled ? 1 : 0
  function_name    = "${var.cluster_name}-reaper"
  description      = "Auto-deletes lab ${var.cluster_name} at expiry"
  role             = aws_iam_role.reaper[0].arn
  runtime          = "python3.12"
  handler          = "reaper.handler"
  filename         = data.archive_file.reaper[0].output_path
  source_code_hash = data.archive_file.reaper[0].output_base64sha256
  timeout          = 900
  memory_size      = 256

  environment {
    variables = {
      CLUSTER_NAME = var.cluster_name
      REGION       = var.region
      DRY_RUN      = tostring(var.expiry_dry_run)
    }
  }

  tags = {
    Name    = "${var.cluster_name}-reaper"
    Cluster = var.cluster_name
  }
}

# ---- EventBridge Scheduler (one-shot) --------------------------------------
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count              = local.expiry_enabled ? 1 : 0
  name               = "${var.cluster_name}-expiry-sched-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json

  tags = {
    Name    = "${var.cluster_name}-expiry-sched-role"
    Cluster = var.cluster_name
  }
}

resource "aws_iam_role_policy" "scheduler" {
  count = local.expiry_enabled ? 1 : 0
  name  = "${var.cluster_name}-expiry-sched-policy"
  role  = aws_iam_role.scheduler[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.reaper[0].arn
    }]
  })
}

resource "aws_scheduler_schedule" "expiry" {
  count = local.expiry_enabled ? 1 : 0
  name  = "${var.cluster_name}-expiry"

  flexible_time_window {
    mode = "OFF"
  }

  # EventBridge at() wants a timezone-naive ISO-8601 timestamp; strip the "Z".
  schedule_expression          = "at(${formatdate("YYYY-MM-DD'T'hh:mm:ss", time_offset.expiry[0].rfc3339)})"
  schedule_expression_timezone = "UTC"

  # The schedule is deleted by the reaper itself in self_destruct() (reaper.py),
  # which keeps all self-cleanup in one place and avoids a hard dependency on
  # the provider's action_after_completion attribute.

  target {
    arn      = aws_lambda_function.reaper[0].arn
    role_arn = aws_iam_role.scheduler[0].arn
  }
}

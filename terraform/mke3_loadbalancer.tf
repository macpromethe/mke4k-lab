# ---------------------------------------------------------------------------
# MKE3 NLB — only created when mke3_enabled = true
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Security Group
# ---------------------------------------------------------------------------
resource "aws_security_group" "mke3_nlb" {
  count       = var.mke3_enabled ? 1 : 0
  name        = "${var.cluster_name}-mke3-nlb-sg"
  description = "MKE3 NLB - inbound on 443 and 6443, outbound to cluster nodes"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "MKE3 UI / HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "MKE3 UI to cluster nodes"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster_allow_ssh.id]
  }

  egress {
    description     = "kube-api to cluster nodes"
    from_port       = 6443
    to_port         = 6443
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster_allow_ssh.id]
  }

  tags = {
    Name    = "${var.cluster_name}-mke3-nlb-sg"
    Cluster = var.cluster_name
  }
}

# ---------------------------------------------------------------------------
# Network Load Balancer
# ---------------------------------------------------------------------------
resource "aws_lb" "mke3" {
  count              = var.mke3_enabled ? 1 : 0
  name               = "${var.cluster_name}-mke3-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.mke3_nlb[0].id]

  tags = {
    Name    = "${var.cluster_name}-mke3-nlb"
    Cluster = var.cluster_name
  }
}

# ---------------------------------------------------------------------------
# Target Groups
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "mke3_mke" {
  count    = var.mke3_enabled ? 1 : 0
  name     = "${var.cluster_name}-mke3-mke"
  port     = 443
  protocol = "TCP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name    = "${var.cluster_name}-mke3-mke"
    Cluster = var.cluster_name
  }
}

resource "aws_lb_target_group" "mke3_kube" {
  count    = var.mke3_enabled ? 1 : 0
  name     = "${var.cluster_name}-mke3-kube"
  port     = 6443
  protocol = "TCP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name    = "${var.cluster_name}-mke3-kube"
    Cluster = var.cluster_name
  }
}

# ---------------------------------------------------------------------------
# Listeners
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "mke3_mke" {
  count             = var.mke3_enabled ? 1 : 0
  load_balancer_arn = aws_lb.mke3[0].arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mke3_mke[0].arn
  }
}

resource "aws_lb_listener" "mke3_kube" {
  count             = var.mke3_enabled ? 1 : 0
  load_balancer_arn = aws_lb.mke3[0].arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mke3_kube[0].arn
  }
}

# ---------------------------------------------------------------------------
# Target group attachments — all controllers on both target groups
# ---------------------------------------------------------------------------
resource "aws_lb_target_group_attachment" "mke3_mke" {
  count            = var.mke3_enabled ? var.controller_count : 0
  target_group_arn = aws_lb_target_group.mke3_mke[0].arn
  target_id        = aws_instance.cluster-controller[count.index].id
  port             = 443
}

resource "aws_lb_target_group_attachment" "mke3_kube" {
  count            = var.mke3_enabled ? var.controller_count : 0
  target_group_arn = aws_lb_target_group.mke3_kube[0].arn
  target_id        = aws_instance.cluster-controller[count.index].id
  port             = 6443
}

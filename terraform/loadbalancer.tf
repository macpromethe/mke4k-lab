# ---------------------------------------------------------------------------
# NLB Security Group
# ---------------------------------------------------------------------------
resource "aws_security_group" "nlb" {
  name        = "${var.cluster_name}-nlb-sg"
  description = "MKE4k NLB - inbound on listener ports, outbound to cluster nodes"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "MKE API / controller join"
    from_port   = 9443
    to_port     = 9443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS / ingress"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound only to the cluster node SG on the backend ports
  egress {
    description     = "kube-api to cluster nodes"
    from_port       = 6443
    to_port         = 6443
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster_allow_ssh.id]
  }

  egress {
    description     = "MKE API to cluster nodes"
    from_port       = 9443
    to_port         = 9443
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster_allow_ssh.id]
  }

  egress {
    description     = "Ingress to cluster nodes"
    from_port       = 33001
    to_port         = 33001
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster_allow_ssh.id]
  }

  tags = {
    Name    = "${var.cluster_name}-nlb-sg"
    Cluster = var.cluster_name
  }
}

# ---------------------------------------------------------------------------
# Network Load Balancer
# ---------------------------------------------------------------------------
resource "aws_lb" "cluster" {
  name               = "${var.cluster_name}-nlb"
  internal           = var.airgap_enabled
  load_balancer_type = "network"
  subnets            = var.airgap_enabled ? [aws_subnet.airgap_private[0].id] : [aws_subnet.public.id]
  security_groups    = [aws_security_group.nlb.id]

  tags = {
    Name    = "${var.cluster_name}-nlb"
    Cluster = var.cluster_name
  }
}

# ---------------------------------------------------------------------------
# Target Groups
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "kube_api" {
  name        = "${var.cluster_name}-kube-api"
  port        = 6443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.lab.id

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name    = "${var.cluster_name}-kube-api"
    Cluster = var.cluster_name
  }
}

resource "aws_lb_target_group" "controller_join" {
  name        = "${var.cluster_name}-ctrl-join"
  port        = 9443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.lab.id

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name    = "${var.cluster_name}-ctrl-join"
    Cluster = var.cluster_name
  }
}

resource "aws_lb_target_group" "ingress" {
  name        = "${var.cluster_name}-ingress"
  port        = 33001
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.lab.id

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name    = "${var.cluster_name}-ingress"
    Cluster = var.cluster_name
  }
}

# ---------------------------------------------------------------------------
# Listeners
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "kube_api" {
  load_balancer_arn = aws_lb.cluster.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kube_api.arn
  }
}

resource "aws_lb_listener" "controller_join" {
  load_balancer_arn = aws_lb.cluster.arn
  port              = 9443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.controller_join.arn
  }
}

resource "aws_lb_listener" "ingress" {
  load_balancer_arn = aws_lb.cluster.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress.arn
  }
}

# ---------------------------------------------------------------------------
# Target group attachments — all controllers on all three target groups
# ---------------------------------------------------------------------------
resource "aws_lb_target_group_attachment" "kube_api" {
  count            = var.controller_count
  target_group_arn = aws_lb_target_group.kube_api.arn
  target_id        = aws_instance.cluster-controller[count.index].private_ip
  port             = 6443
}

resource "aws_lb_target_group_attachment" "controller_join" {
  count            = var.controller_count
  target_group_arn = aws_lb_target_group.controller_join.arn
  target_id        = aws_instance.cluster-controller[count.index].private_ip
  port             = 9443
}

resource "aws_lb_target_group_attachment" "ingress" {
  count            = var.controller_count
  target_group_arn = aws_lb_target_group.ingress.arn
  target_id        = aws_instance.cluster-controller[count.index].private_ip
  port             = 33001
}

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

  ingress {
    description = "KOF Grafana"
    from_port   = var.kof_grafana_lb_port
    to_port     = var.kof_grafana_lb_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "k0rdent UI"
    from_port   = var.k0rdent_ui_lb_port
    to_port     = var.k0rdent_ui_lb_port
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

  egress {
    description     = "KOF Grafana gateway to cluster nodes"
    from_port       = var.kof_grafana_nodeport
    to_port         = var.kof_grafana_nodeport
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster_allow_ssh.id]
  }

  egress {
    description     = "k0rdent UI gateway to cluster nodes"
    from_port       = var.k0rdent_ui_nodeport
    to_port         = var.k0rdent_ui_nodeport
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

# ---------------------------------------------------------------------------
# KOF Grafana — dedicated listener + target group → Envoy gateway NodePort
# (TCP pass-through; the kof Envoy gateway terminates TLS). Gated on the toggle.
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "kof_grafana" {
  count       = var.kof_grafana_gateway_enabled ? 1 : 0
  name        = "${var.cluster_name}-kof-grafana"
  port        = var.kof_grafana_nodeport
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
    Name    = "${var.cluster_name}-kof-grafana"
    Cluster = var.cluster_name
  }
}

resource "aws_lb_listener" "kof_grafana" {
  count             = var.kof_grafana_gateway_enabled ? 1 : 0
  load_balancer_arn = aws_lb.cluster.arn
  port              = var.kof_grafana_lb_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kof_grafana[0].arn
  }
}

resource "aws_lb_target_group_attachment" "kof_grafana" {
  count            = var.kof_grafana_gateway_enabled ? var.controller_count : 0
  target_group_arn = aws_lb_target_group.kof_grafana[0].arn
  target_id        = aws_instance.cluster-controller[count.index].private_ip
  port             = var.kof_grafana_nodeport
}

# ---------------------------------------------------------------------------
# k0rdent UI — dedicated listener + target group → Envoy gateway NodePort
# (TCP pass-through; the k0rdent UI Envoy gateway terminates TLS). Gated on the toggle.
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "k0rdent_ui" {
  count       = var.k0rdent_ui_enabled ? 1 : 0
  name        = "${var.cluster_name}-k0rdent-ui"
  port        = var.k0rdent_ui_nodeport
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
    Name    = "${var.cluster_name}-k0rdent-ui"
    Cluster = var.cluster_name
  }
}

resource "aws_lb_listener" "k0rdent_ui" {
  count             = var.k0rdent_ui_enabled ? 1 : 0
  load_balancer_arn = aws_lb.cluster.arn
  port              = var.k0rdent_ui_lb_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k0rdent_ui[0].arn
  }
}

resource "aws_lb_target_group_attachment" "k0rdent_ui" {
  count            = var.k0rdent_ui_enabled ? var.controller_count : 0
  target_group_arn = aws_lb_target_group.k0rdent_ui[0].arn
  target_id        = aws_instance.cluster-controller[count.index].private_ip
  port             = var.k0rdent_ui_nodeport
}

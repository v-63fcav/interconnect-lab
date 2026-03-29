# =============================================================================
# AWS PRIVATELINK
# =============================================================================
# PrivateLink enables you to expose a service from one VPC to consumers in
# another VPC WITHOUT any network-level connectivity (no TGW, no peering,
# no internet). The consumer only gets access to the specific service port.
#
# PRODUCER (vpc-app-b): NLB -> Endpoint Service
# CONSUMER (vpc-vendor): Interface VPC Endpoint -> ENI in vendor subnet
# =============================================================================

# --- Producer: NLB in vpc-app-b ---

resource "aws_lb" "privatelink" {
  name               = "${var.project_name}-pl-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = [aws_subnet.app_b_private.id]

  tags = { Name = "${var.project_name}-privatelink-nlb" }
}

resource "aws_lb_target_group" "privatelink" {
  name     = "${var.project_name}-pl-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.app_b.id

  health_check {
    protocol            = "TCP"
    port                = 80
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 10
  }

  tags = { Name = "${var.project_name}-privatelink-tg" }
}

resource "aws_lb_listener" "privatelink" {
  load_balancer_arn = aws_lb.privatelink.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.privatelink.arn
  }
}

# --- Producer: VPC Endpoint Service ---

resource "aws_vpc_endpoint_service" "app_b" {
  acceptance_required        = false
  network_load_balancer_arns = [aws_lb.privatelink.arn]

  tags = { Name = "${var.project_name}-privatelink-service" }
}

# --- Consumer: Interface Endpoint in vpc-vendor ---

resource "aws_security_group" "vendor_privatelink" {
  name_prefix = "${var.project_name}-vendor-pl-"
  vpc_id      = aws_vpc.vendor.id
  description = "Allow HTTP to PrivateLink endpoint in vpc-vendor"

  ingress {
    description = "HTTP from vpc-vendor"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidrs["vendor"]]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-vendor-privatelink-sg" }
}

resource "aws_vpc_endpoint" "vendor_privatelink" {
  vpc_id              = aws_vpc.vendor.id
  service_name        = aws_vpc_endpoint_service.app_b.service_name
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = false

  subnet_ids         = [aws_subnet.vendor_isolated.id]
  security_group_ids = [aws_security_group.vendor_privatelink.id]

  tags = { Name = "${var.project_name}-vendor-privatelink-vpce" }
}

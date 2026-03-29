# =============================================================================
# VPC ENDPOINTS
# =============================================================================
# VPC Endpoints let you access AWS services (S3, SSM, STS, etc.) without
# traversing the public internet. Two types:
#
# 1. GATEWAY ENDPOINTS (S3, DynamoDB only) — Free, route table entries
# 2. INTERFACE ENDPOINTS (all other services) — ~$0.01/hr/AZ, creates ENI
# =============================================================================

# --- Security Groups for Interface Endpoints ---

resource "aws_security_group" "shared_endpoints" {
  name_prefix = "${var.project_name}-shared-vpce-"
  vpc_id      = aws_vpc.shared.id
  description = "Allow HTTPS to VPC Interface Endpoints in vpc-shared"

  ingress {
    description = "HTTPS from vpc-shared"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidrs["shared"]]
  }

  ingress {
    description = "HTTPS from vpc-app-a via TGW"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidrs["app_a"]]
  }

  ingress {
    description = "HTTPS from vpc-app-b via TGW"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidrs["app_b"]]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-shared-vpce-sg" }
}

resource "aws_security_group" "vendor_endpoints" {
  name_prefix = "${var.project_name}-vendor-vpce-"
  vpc_id      = aws_vpc.vendor.id
  description = "Allow HTTPS to VPC Interface Endpoints in vpc-vendor"

  ingress {
    description = "HTTPS from vpc-vendor"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidrs["vendor"]]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-vendor-vpce-sg" }
}

# --- Gateway Endpoints: S3 ---

resource "aws_vpc_endpoint" "shared_s3" {
  vpc_id            = aws_vpc.shared.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.shared_public.id,
    aws_route_table.shared_private.id,
    aws_route_table.shared_isolated.id,
  ]

  tags = { Name = "${var.project_name}-shared-s3-gwep" }
}

resource "aws_vpc_endpoint" "app_a_s3" {
  vpc_id            = aws_vpc.app_a.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.app_a_public.id,
    aws_route_table.app_a_private.id,
    aws_route_table.app_a_isolated.id,
  ]

  tags = { Name = "${var.project_name}-app-a-s3-gwep" }
}

resource "aws_vpc_endpoint" "app_b_s3" {
  vpc_id            = aws_vpc.app_b.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.app_b_public.id,
    aws_route_table.app_b_private.id,
    aws_route_table.app_b_isolated.id,
  ]

  tags = { Name = "${var.project_name}-app-b-s3-gwep" }
}

# --- Interface Endpoints: SSM + STS (vpc-shared — centralized) ---

resource "aws_vpc_endpoint" "shared_ssm" {
  vpc_id              = aws_vpc.shared.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssm"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.shared_isolated.id]
  security_group_ids = [aws_security_group.shared_endpoints.id]

  tags = { Name = "${var.project_name}-shared-ssm-vpce" }
}

resource "aws_vpc_endpoint" "shared_ssmmessages" {
  vpc_id              = aws_vpc.shared.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.shared_isolated.id]
  security_group_ids = [aws_security_group.shared_endpoints.id]

  tags = { Name = "${var.project_name}-shared-ssmmessages-vpce" }
}

resource "aws_vpc_endpoint" "shared_ec2messages" {
  vpc_id              = aws_vpc.shared.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.shared_isolated.id]
  security_group_ids = [aws_security_group.shared_endpoints.id]

  tags = { Name = "${var.project_name}-shared-ec2messages-vpce" }
}

resource "aws_vpc_endpoint" "shared_sts" {
  vpc_id              = aws_vpc.shared.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.shared_isolated.id]
  security_group_ids = [aws_security_group.shared_endpoints.id]

  tags = { Name = "${var.project_name}-shared-sts-vpce" }
}

# --- Interface Endpoints: SSM + STS (vpc-vendor — isolated, needs own) ---

resource "aws_vpc_endpoint" "vendor_ssm" {
  vpc_id              = aws_vpc.vendor.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssm"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.vendor_isolated.id]
  security_group_ids = [aws_security_group.vendor_endpoints.id]

  tags = { Name = "${var.project_name}-vendor-ssm-vpce" }
}

resource "aws_vpc_endpoint" "vendor_ssmmessages" {
  vpc_id              = aws_vpc.vendor.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.vendor_isolated.id]
  security_group_ids = [aws_security_group.vendor_endpoints.id]

  tags = { Name = "${var.project_name}-vendor-ssmmessages-vpce" }
}

resource "aws_vpc_endpoint" "vendor_ec2messages" {
  vpc_id              = aws_vpc.vendor.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.vendor_isolated.id]
  security_group_ids = [aws_security_group.vendor_endpoints.id]

  tags = { Name = "${var.project_name}-vendor-ec2messages-vpce" }
}

resource "aws_vpc_endpoint" "vendor_sts" {
  vpc_id              = aws_vpc.vendor.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [aws_subnet.vendor_isolated.id]
  security_group_ids = [aws_security_group.vendor_endpoints.id]

  tags = { Name = "${var.project_name}-vendor-sts-vpce" }
}

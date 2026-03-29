# -----------------------------------------------------------------------------
# Outputs consumed by the compute layer (via terraform_remote_state)
# -----------------------------------------------------------------------------

# VPC IDs
output "vpc_shared_id" {
  value = aws_vpc.shared.id
}

output "vpc_app_a_id" {
  value = aws_vpc.app_a.id
}

output "vpc_app_b_id" {
  value = aws_vpc.app_b.id
}

output "vpc_vendor_id" {
  value = aws_vpc.vendor.id
}

# Subnet IDs
output "subnet_shared_public_id" {
  value = aws_subnet.shared_public.id
}

output "subnet_shared_isolated_id" {
  value = aws_subnet.shared_isolated.id
}

output "subnet_app_a_private_id" {
  value = aws_subnet.app_a_private.id
}

output "subnet_app_a_isolated_id" {
  value = aws_subnet.app_a_isolated.id
}

output "subnet_app_b_private_id" {
  value = aws_subnet.app_b_private.id
}

output "subnet_vendor_isolated_id" {
  value = aws_subnet.vendor_isolated.id
}

# IAM
output "ssm_instance_profile_name" {
  value = aws_iam_instance_profile.ssm.name
}

# PrivateLink
output "privatelink_target_group_arn" {
  value = aws_lb_target_group.privatelink.arn
}

output "privatelink_endpoint_dns" {
  value = try(aws_vpc_endpoint.vendor_privatelink.dns_entry[0].dns_name, "")
}

# S3
output "test_bucket_name" {
  value = aws_s3_bucket.test.id
}

# -----------------------------------------------------------------------------
# VPN tunnel details — feed into GCP var.aws_vpn_tunnels after AWS apply
# Each AWS VPN connection creates 2 tunnels. We have 2 connections = 4 tunnels.
# Connection 0 maps to GCP HA VPN interface 0, connection 1 to interface 1.
# -----------------------------------------------------------------------------
output "vpn_tunnel_details" {
  description = "AWS VPN tunnel configs — paste into GCP aws_vpn_tunnels variable"
  sensitive   = true
  value = var.create_vpn && length(var.gcp_vpn_gateway_ips) == 2 ? [
    {
      outside_ip       = aws_vpn_connection.gcp[0].tunnel1_address
      psk              = aws_vpn_connection.gcp[0].tunnel1_preshared_key
      aws_inside_ip    = aws_vpn_connection.gcp[0].tunnel1_vgw_inside_address
      gcp_inside_ip    = aws_vpn_connection.gcp[0].tunnel1_cgw_inside_address
      vpn_gw_interface = 0
    },
    {
      outside_ip       = aws_vpn_connection.gcp[0].tunnel2_address
      psk              = aws_vpn_connection.gcp[0].tunnel2_preshared_key
      aws_inside_ip    = aws_vpn_connection.gcp[0].tunnel2_vgw_inside_address
      gcp_inside_ip    = aws_vpn_connection.gcp[0].tunnel2_cgw_inside_address
      vpn_gw_interface = 0
    },
    {
      outside_ip       = aws_vpn_connection.gcp[1].tunnel1_address
      psk              = aws_vpn_connection.gcp[1].tunnel1_preshared_key
      aws_inside_ip    = aws_vpn_connection.gcp[1].tunnel1_vgw_inside_address
      gcp_inside_ip    = aws_vpn_connection.gcp[1].tunnel1_cgw_inside_address
      vpn_gw_interface = 1
    },
    {
      outside_ip       = aws_vpn_connection.gcp[1].tunnel2_address
      psk              = aws_vpn_connection.gcp[1].tunnel2_preshared_key
      aws_inside_ip    = aws_vpn_connection.gcp[1].tunnel2_vgw_inside_address
      gcp_inside_ip    = aws_vpn_connection.gcp[1].tunnel2_cgw_inside_address
      vpn_gw_interface = 1
    },
  ] : []
}

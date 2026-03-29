# =============================================================================
# HA VPN TO GCP (Multi-Cloud Connectivity)
# =============================================================================
# Connects AWS Transit Gateway to GCP sl-gke-vpc via HA VPN with BGP.
# Two VPN connections (one per GCP HA VPN interface) provide 4 tunnels
# total for full HA on both sides.
#
# GCP advertises translated CIDRs (10.100.x, 10.101.x, 10.102.x) via BGP
# to avoid overlap with AWS VPCs (10.0-2.x). TGW auto-propagates these
# learned routes to its route table, making GKE services reachable from
# all TGW-attached VPCs without any manual route table changes.
#
# Deploy order (chicken-and-egg):
#   1. GCP: terraform apply (create_vpn=true) → get HA VPN external IPs
#   2. AWS: terraform apply (create_vpn=true, gcp_vpn_gateway_ips=[...])
#           → get tunnel IPs, PSKs, BGP addresses (from outputs)
#   3. GCP: terraform apply (aws_vpn_tunnels=[...]) → tunnels + BGP come up
#
# Cost: ~$0.05/hr per VPN connection × 2 = ~$73/mo
# =============================================================================

# --- Customer Gateways (one per GCP HA VPN interface) ---
# A Customer Gateway represents the remote end of the VPN (GCP in this case).
# We create 2 because GCP HA VPN has 2 interfaces for redundancy.

resource "aws_customer_gateway" "gcp" {
  count = var.create_vpn && length(var.gcp_vpn_gateway_ips) == 2 ? 2 : 0

  bgp_asn    = var.gcp_bgp_asn
  ip_address = var.gcp_vpn_gateway_ips[count.index]
  type       = "ipsec.1"

  tags = { Name = "${var.project_name}-gcp-cgw-${count.index}" }
}

# --- VPN Connections (2 connections x 2 tunnels each = 4 tunnels) ---
# Each VPN connection creates 2 tunnels automatically for redundancy.
# BGP is used for dynamic route exchange — GCP Cloud Router advertises
# translated CIDRs, and TGW propagates them to its route table.

resource "aws_vpn_connection" "gcp" {
  count = var.create_vpn && length(var.gcp_vpn_gateway_ips) == 2 ? 2 : 0

  customer_gateway_id = aws_customer_gateway.gcp[count.index].id
  transit_gateway_id  = aws_ec2_transit_gateway.main.id
  type                = "ipsec.1"

  # BGP dynamic routing — GCP will advertise translated CIDRs
  static_routes_only = false

  tags = { Name = "${var.project_name}-gcp-vpn-${count.index}" }
}

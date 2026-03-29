# =============================================================================
# HA VPN TO AWS
# =============================================================================
# Connects GCP interconnect-lab-vpc to AWS Transit Gateway via HA VPN.
# GCP CIDRs overlap with AWS (10.0-2.x), so Cloud Router advertises
# translated ranges (10.100.x, 10.101.x, 10.102.x). A NAT VM in
# nat-vm.tf handles bidirectional translation.
#
# Deploy order (chicken-and-egg):
#   1. GCP: apply with create_vpn=true, aws_vpn_tunnels=[] -> get HA VPN IPs
#   2. AWS: apply with gcp_vpn_gateway_ips=[...] -> get tunnel IPs/PSKs
#   3. GCP: apply with aws_vpn_tunnels=[...] -> tunnels + BGP come up
# =============================================================================

# --- HA VPN Gateway (2 external IPs for redundancy) ---
resource "google_compute_ha_vpn_gateway" "to_aws" {
  count   = var.create_vpn ? 1 : 0
  name    = "interconnect-lab-vpn-to-aws"
  network = google_compute_network.vpc.id
  region  = var.gcp_region
}

# --- External VPN Gateway (represents the 4 AWS VPN tunnel endpoints) ---
resource "google_compute_external_vpn_gateway" "aws" {
  count           = var.create_vpn && length(var.aws_vpn_tunnels) > 0 ? 1 : 0
  name            = "interconnect-lab-aws-vpn-gw"
  redundancy_type = "FOUR_IPS_REDUNDANCY"

  dynamic "interface" {
    for_each = var.aws_vpn_tunnels
    content {
      id         = interface.key
      ip_address = interface.value.outside_ip
    }
  }
}

# --- VPN Tunnels (one per AWS tunnel endpoint) ---
resource "google_compute_vpn_tunnel" "to_aws" {
  count = var.create_vpn ? length(var.aws_vpn_tunnels) : 0

  name                            = "interconnect-lab-to-aws-tunnel-${count.index}"
  region                          = var.gcp_region
  vpn_gateway                     = google_compute_ha_vpn_gateway.to_aws[0].id
  vpn_gateway_interface           = var.aws_vpn_tunnels[count.index].vpn_gw_interface
  peer_external_gateway           = google_compute_external_vpn_gateway.aws[0].id
  peer_external_gateway_interface = count.index
  shared_secret                   = var.aws_vpn_tunnels[count.index].psk
  router                          = google_compute_router.router.id
  ike_version                     = 2
}

# --- Cloud Router BGP Interfaces ---
resource "google_compute_router_interface" "aws" {
  count = var.create_vpn ? length(var.aws_vpn_tunnels) : 0

  name       = "interconnect-lab-aws-bgp-if-${count.index}"
  router     = google_compute_router.router.name
  region     = var.gcp_region
  ip_range   = "${var.aws_vpn_tunnels[count.index].gcp_inside_ip}/30"
  vpn_tunnel = google_compute_vpn_tunnel.to_aws[count.index].name
}

# --- BGP Peers (custom route advertisements with translated CIDRs) ---
resource "google_compute_router_peer" "aws" {
  count = var.create_vpn ? length(var.aws_vpn_tunnels) : 0

  name                      = "interconnect-lab-aws-bgp-peer-${count.index}"
  router                    = google_compute_router.router.name
  region                    = var.gcp_region
  peer_ip_address           = var.aws_vpn_tunnels[count.index].aws_inside_ip
  peer_asn                  = var.aws_bgp_asn
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.aws[count.index].name

  # CRITICAL: Advertise translated CIDRs, not real ones.
  # This avoids overlap with AWS VPCs (10.0-2.0.0/16).
  advertise_mode = "CUSTOM"
  advertised_ip_ranges {
    range       = var.translated_cidrs.nodes
    description = "Translated node CIDR (real: ${var.vpc_cidr})"
  }
  advertised_ip_ranges {
    range       = var.translated_cidrs.pods
    description = "Translated pod CIDR (real: ${var.pods_cidr})"
  }
  advertised_ip_ranges {
    range       = var.translated_cidrs.services
    description = "Translated service CIDR (real: ${var.services_cidr})"
  }
}

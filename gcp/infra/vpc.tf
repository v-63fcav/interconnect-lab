resource "google_compute_network" "vpc" {
  name                    = "interconnect-lab-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "nodes" {
  name          = "interconnect-lab-nodes"
  ip_cidr_range = var.vpc_cidr
  region        = var.gcp_region
  network       = google_compute_network.vpc.id

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# Cloud Router — used by both Cloud NAT (outbound internet) and HA VPN (BGP).
# The bgp block is only added when VPN is enabled.
resource "google_compute_router" "router" {
  name    = "interconnect-lab-router"
  region  = var.gcp_region
  network = google_compute_network.vpc.id

  dynamic "bgp" {
    for_each = var.create_vpn ? [1] : []
    content {
      asn = var.gcp_bgp_asn
    }
  }
}

# Cloud NAT — outbound internet for private GKE nodes
resource "google_compute_router_nat" "nat" {
  name                               = "interconnect-lab-nat"
  router                             = google_compute_router.router.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

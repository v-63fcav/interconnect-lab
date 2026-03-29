# =============================================================================
# NAT GATEWAY VM
# =============================================================================
# Handles bidirectional NAT translation for overlapping CIDRs between
# AWS (10.0-2.x) and GCP (10.0-2.x). Traffic from AWS arrives addressed
# to translated GCP ranges (10.100.x, 10.101.x, 10.102.x) and this VM
# DNATs them to real GCP IPs, then MASQUERADEs the source.
#
# Why not GCP Private NAT? Private NAT only handles SNAT (outbound).
# For inbound DNAT (AWS->GCP), a NAT VM is the standard pattern.
#
# MASQUERADE is used instead of SNAT/NETMAP because overlapping CIDRs
# make source IPs ambiguous. MASQUERADE rewrites source to the NAT VM's
# own IP, which is always unambiguous. Tradeoff: ~65k concurrent connections
# max (single source IP port space). Fine for a lab.
# =============================================================================

data "google_compute_image" "debian" {
  count   = var.create_vpn ? 1 : 0
  family  = "debian-12"
  project = "debian-cloud"
}

resource "google_compute_instance" "nat_gateway" {
  count        = var.create_vpn ? 1 : 0
  name         = "interconnect-lab-nat-gateway"
  machine_type = "e2-micro"
  zone         = data.google_compute_zones.available.names[0]

  # CRITICAL: Allows the VM to forward packets (act as a router)
  can_ip_forward = true

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian[0].self_link
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.nodes.id
  }

  metadata_startup_script = <<-SCRIPT
    #!/bin/bash
    set -e

    # Enable IP forwarding at kernel level
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/99-nat.conf
    sysctl -p /etc/sysctl.d/99-nat.conf

    # DNAT: Translate virtual->real destinations (AWS->GCP traffic)
    iptables -t nat -A PREROUTING -d ${var.translated_cidrs.nodes} -j NETMAP --to ${var.vpc_cidr}
    iptables -t nat -A PREROUTING -d ${var.translated_cidrs.pods} -j NETMAP --to ${var.pods_cidr}
    iptables -t nat -A PREROUTING -d ${var.translated_cidrs.services} -j NETMAP --to ${var.services_cidr}

    # MASQUERADE: Rewrite source to NAT VM's IP (avoids overlap ambiguity)
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

    # Persist rules across reboots
    apt-get update -qq && apt-get install -y -qq iptables-persistent
    netfilter-persistent save
  SCRIPT

  service_account {
    email  = google_service_account.gke_nodes.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  tags = ["nat-gateway"]

  depends_on = [google_compute_router_nat.nat]
}

# --- VPC Routes: Translated CIDRs -> NAT VM ---
# When traffic arrives from VPN for 10.100.x.x, the VPC routes it to the
# NAT VM, which DNATs to real 10.0.x.x and forwards within the VPC.

resource "google_compute_route" "nat_nodes" {
  count                  = var.create_vpn ? 1 : 0
  name                   = "interconnect-lab-nat-route-nodes"
  network                = google_compute_network.vpc.id
  dest_range             = var.translated_cidrs.nodes
  next_hop_instance      = google_compute_instance.nat_gateway[0].id
  next_hop_instance_zone = data.google_compute_zones.available.names[0]
  priority               = 100
}

resource "google_compute_route" "nat_pods" {
  count                  = var.create_vpn ? 1 : 0
  name                   = "interconnect-lab-nat-route-pods"
  network                = google_compute_network.vpc.id
  dest_range             = var.translated_cidrs.pods
  next_hop_instance      = google_compute_instance.nat_gateway[0].id
  next_hop_instance_zone = data.google_compute_zones.available.names[0]
  priority               = 100
}

resource "google_compute_route" "nat_services" {
  count                  = var.create_vpn ? 1 : 0
  name                   = "interconnect-lab-nat-route-services"
  network                = google_compute_network.vpc.id
  dest_range             = var.translated_cidrs.services
  next_hop_instance      = google_compute_instance.nat_gateway[0].id
  next_hop_instance_zone = data.google_compute_zones.available.names[0]
  priority               = 100
}

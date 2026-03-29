# Allow all traffic within RFC-1918 space (intra-cluster, cross-cloud via VPN)
resource "google_compute_firewall" "allow_internal" {
  name    = "interconnect-lab-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "all"
  }

  source_ranges = [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
  ]
}

# Allow GCP health check probes for Load Balancers
resource "google_compute_firewall" "allow_health_checks" {
  name    = "interconnect-lab-allow-health-checks"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
  }

  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]
}

output "cluster_name" {
  value       = google_container_cluster.primary.name
  description = "GKE cluster name"
}

output "cluster_endpoint" {
  value       = google_container_cluster.primary.endpoint
  description = "GKE control plane API endpoint"
  sensitive   = true
}

output "cluster_ca" {
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  description = "GKE cluster CA certificate (base64-encoded PEM)"
  sensitive   = true
}

output "region" {
  value       = var.gcp_region
  description = "GCP region"
}

output "project" {
  value       = var.gcp_project
  description = "GCP project ID"
}

output "node_service_account" {
  value       = google_service_account.gke_nodes.email
  description = "Node pool service account email"
}

# HA VPN gateway external IPs — feed into AWS var.gcp_vpn_gateway_ips
output "vpn_gateway_ips" {
  description = "HA VPN gateway external IPs (feed into AWS gcp_vpn_gateway_ips variable)"
  value = var.create_vpn ? [
    google_compute_ha_vpn_gateway.to_aws[0].vpn_interfaces[0].ip_address,
    google_compute_ha_vpn_gateway.to_aws[0].vpn_interfaces[1].ip_address,
  ] : []
}

# NAT VM internal IP (for debugging)
output "nat_gateway_ip" {
  description = "NAT gateway VM internal IP"
  value       = var.create_vpn ? google_compute_instance.nat_gateway[0].network_interface[0].network_ip : ""
}

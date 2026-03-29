variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "interconnect-lab"
}

variable "create_vpn" {
  description = "Whether to create the HA VPN connections to GCP. Costs ~$0.05/hr per connection when enabled."
  type        = bool
  default     = false
}

variable "create_nat_gateways" {
  description = "Whether to create NAT Gateways for private subnets. Costs ~$0.135/hr total (3 NAT GWs). Set to false to save cost and focus on public/isolated testing only."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# VPC CIDRs — each VPC gets a /16 within the 10.0.0.0/8 private range.
# Non-overlapping CIDRs are critical for TGW and peering to work correctly.
# NOTE: GCP sl-gke uses 10.0.0.0/16, 10.1.0.0/16, 10.2.0.0/20 — these
# overlap with shared, app-a, app-b. NAT translation on the GCP side handles
# this by presenting GCP as 10.100.x, 10.101.x, 10.102.x to AWS.
# -----------------------------------------------------------------------------
variable "vpc_cidrs" {
  description = "CIDR blocks for each VPC"
  type        = map(string)
  default = {
    shared = "10.0.0.0/16"
    app_a  = "10.1.0.0/16"
    app_b  = "10.2.0.0/16"
    vendor = "10.3.0.0/16"
  }
}

# -----------------------------------------------------------------------------
# GCP HA VPN — populated after GCP Phase 1 apply
# -----------------------------------------------------------------------------
variable "gcp_vpn_gateway_ips" {
  description = "GCP HA VPN gateway external IPs (from gcp/infra output vpn_gateway_ips)"
  type        = list(string)
  default     = []
}

variable "gcp_bgp_asn" {
  description = "GCP Cloud Router BGP ASN"
  type        = number
  default     = 65534
}

variable "gcp_project" {
  default     = "gen-lang-client-0403070412"
  description = "GCP project ID"
}

variable "gcp_region" {
  default     = "us-west1"
  description = "GCP region"
}

variable "vpc_cidr" {
  default     = "10.0.0.0/16"
  description = "Primary CIDR range for the node subnet"
}

variable "pods_cidr" {
  default     = "10.1.0.0/16"
  description = "Secondary CIDR range for pod alias IPs (VPC-native)"
}

variable "services_cidr" {
  default     = "10.2.0.0/20"
  description = "Secondary CIDR range for service alias IPs (VPC-native)"
}

variable "gke_admin_email" {
  default     = "v-63fcav@hotmail.com"
  description = "Google account email to grant GKE and project admin access"
}

# -----------------------------------------------------------------------------
# HA VPN to AWS
# -----------------------------------------------------------------------------
variable "create_vpn" {
  description = "Create HA VPN to AWS (costs ~$0.05/hr per tunnel)"
  type        = bool
  default     = false
}

variable "gcp_bgp_asn" {
  description = "BGP ASN for GCP Cloud Router"
  type        = number
  default     = 65534
}

variable "aws_bgp_asn" {
  description = "BGP ASN for AWS TGW (default is 64512)"
  type        = number
  default     = 64512
}

variable "aws_vpn_tunnels" {
  description = "AWS VPN tunnel configs (populated after AWS apply in Phase 2)"
  type = list(object({
    outside_ip       = string
    psk              = string
    aws_inside_ip    = string
    gcp_inside_ip    = string
    vpn_gw_interface = number
  }))
  default   = []
  sensitive = true
}

# Translated CIDRs advertised to AWS via BGP (avoids overlap)
variable "translated_cidrs" {
  description = "GCP CIDRs as seen by AWS (translated to avoid overlap)"
  type = object({
    nodes    = string
    pods     = string
    services = string
  })
  default = {
    nodes    = "10.100.0.0/16"
    pods     = "10.101.0.0/16"
    services = "10.102.0.0/20"
  }
}

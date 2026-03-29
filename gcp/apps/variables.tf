variable "gcp_project" {
  default     = "gen-lang-client-0403070412"
  description = "GCP project ID"
}

variable "gcp_region" {
  default     = "us-west1"
  description = "GCP region"
}

variable "cluster_name" {
  default     = "interconnect-lab-gke"
  description = "GKE cluster name"
}

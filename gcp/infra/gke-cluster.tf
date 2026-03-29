# Service account for GKE nodes
resource "google_service_account" "gke_nodes" {
  account_id   = "interconnect-lab-node-sa"
  display_name = "GKE Node Service Account"
  description  = "Minimal SA for GKE worker nodes"
}

resource "google_project_iam_member" "gke_node_logging" {
  project = var.gcp_project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_node_monitoring_write" {
  project = var.gcp_project
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_node_monitoring_view" {
  project = var.gcp_project
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_node_artifact_registry" {
  project = var.gcp_project
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# Admin access
resource "google_project_iam_member" "admin_container" {
  project = var.gcp_project
  role    = "roles/container.admin"
  member  = "user:${var.gke_admin_email}"
}

resource "google_project_iam_member" "admin_compute" {
  project = var.gcp_project
  role    = "roles/compute.admin"
  member  = "user:${var.gke_admin_email}"
}

# GKE Cluster
resource "google_container_cluster" "primary" {
  name     = "interconnect-lab-gke"
  location = var.gcp_region

  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.nodes.name

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  workload_identity_config {
    workload_pool = "${var.gcp_project}.svc.id.goog"
  }

  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  release_channel {
    channel = "REGULAR"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }

    horizontal_pod_autoscaling {
      disabled = false
    }

    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  deletion_protection = false

  depends_on = [
    google_project_service.container,
    google_compute_subnetwork.nodes,
  ]
}

data "google_compute_zones" "available" {
  region = var.gcp_region
  status = "UP"
}

# Node pool
resource "google_container_node_pool" "primary" {
  name     = "interconnect-lab-nodes"
  cluster  = google_container_cluster.primary.name
  location = var.gcp_region

  node_locations = slice(sort(data.google_compute_zones.available.names), 0, 2)

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  initial_node_count = 1

  node_config {
    machine_type = "e2-standard-2"
    disk_size_gb = 50
    disk_type    = "pd-ssd"

    service_account = google_service_account.gke_nodes.email

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

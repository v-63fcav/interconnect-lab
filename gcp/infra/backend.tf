terraform {
  backend "gcs" {
    bucket = "sl-gke-tf-state-cavi"
    prefix = "terraform/interconnect-lab/infra"
  }
}

terraform {
  backend "s3" {
    bucket  = "ps-sl-state-bucket-cavi-2"
    key     = "interconnect-lab/aws-compute/terraform.tfstate"
    region  = "us-east-2"
    encrypt = true
  }
}

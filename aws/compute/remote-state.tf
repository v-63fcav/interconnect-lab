data "terraform_remote_state" "networking" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "interconnect-lab/aws-networking/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  net = data.terraform_remote_state.networking.outputs
}

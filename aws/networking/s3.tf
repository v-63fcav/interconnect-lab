# =============================================================================
# S3 TEST BUCKET
# =============================================================================
# Simple S3 bucket with a test object to validate Gateway Endpoint access
# from isolated subnets (zero internet access).
# =============================================================================

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "test" {
  bucket        = "${var.project_name}-test-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = { Name = "${var.project_name}-test-bucket" }
}

resource "aws_s3_bucket_public_access_block" "test" {
  bucket = aws_s3_bucket.test.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "test_file" {
  bucket  = aws_s3_bucket.test.id
  key     = "test.txt"
  content = <<-EOF
    SUCCESS! You accessed this S3 object via the S3 Gateway Endpoint.
    This traffic never left the AWS network.

    Bucket: ${aws_s3_bucket.test.id}
    Region: ${data.aws_region.current.name}
  EOF

  tags = { Name = "gateway-endpoint-test-file" }
}

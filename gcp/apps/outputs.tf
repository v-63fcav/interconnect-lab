output "test_app_ilb_ip" {
  description = "Internal Load Balancer IP for the test app (real GCP IP)"
  value       = kubernetes_service.test_app_ilb.status[0].load_balancer[0].ingress[0].ip
}

output "test_app_translated_ip" {
  description = "Translated IP as seen by AWS (replace 10.0.x with 10.100.x)"
  value       = "Use the ILB IP above and replace the first octet: 10.0.X.Y -> 10.100.X.Y"
}

output "cross_cloud_test_command" {
  description = "Run this from any AWS instance to test cross-cloud connectivity"
  value       = "curl http://10.100.${join(".", slice(split(".", kubernetes_service.test_app_ilb.status[0].load_balancer[0].ingress[0].ip), 1, 4))}:80"
}

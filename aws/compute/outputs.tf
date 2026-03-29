# =============================================================================
# OUTPUTS
# =============================================================================

output "instance_ids" {
  description = "Instance IDs for SSM Session Manager access"
  value = {
    shared_public   = aws_instance.shared_public.id
    shared_isolated = aws_instance.shared_isolated.id
    app_a_private   = aws_instance.app_a_private.id
    app_a_isolated  = aws_instance.app_a_isolated.id
    app_b_private   = aws_instance.app_b_private.id
    vendor_isolated = aws_instance.vendor_isolated.id
  }
}

output "private_ips" {
  description = "Private IPs for connectivity testing"
  value = {
    shared_public   = aws_instance.shared_public.private_ip
    shared_isolated = aws_instance.shared_isolated.private_ip
    app_a_private   = aws_instance.app_a_private.private_ip
    app_a_isolated  = aws_instance.app_a_isolated.private_ip
    app_b_private   = aws_instance.app_b_private.private_ip
    vendor_isolated = aws_instance.vendor_isolated.private_ip
  }
}

output "shared_public_ip" {
  description = "Public IP of shared-public instance"
  value       = aws_instance.shared_public.public_ip
}

output "test_commands" {
  description = "Ready-to-run test commands"
  value       = <<-EOT

    ======================================================================
                         QUICK-START TEST COMMANDS
    ======================================================================

    -- SSM Session Manager Access ------------------------------------------
    aws ssm start-session --target ${aws_instance.shared_public.id}      # shared-public
    aws ssm start-session --target ${aws_instance.shared_isolated.id}    # shared-isolated
    aws ssm start-session --target ${aws_instance.app_a_private.id}     # app-a-private
    aws ssm start-session --target ${aws_instance.app_a_isolated.id}    # app-a-isolated
    aws ssm start-session --target ${aws_instance.app_b_private.id}     # app-b-private
    aws ssm start-session --target ${aws_instance.vendor_isolated.id}   # vendor-isolated

    -- AWS Internal Tests --------------------------------------------------
    # From shared-public: test internet
    curl -s ifconfig.me

    # From app-a-private: ping app-b via TGW
    ping -c 3 ${aws_instance.app_b_private.private_ip}

    # From app-a-private: traceroute to shared (should be direct via peering)
    traceroute ${aws_instance.shared_public.private_ip}

    # From shared-isolated: S3 Gateway Endpoint
    aws s3 ls s3://${local.net.test_bucket_name}

    # From vendor-isolated: PrivateLink
    curl http://${local.net.privatelink_endpoint_dns}

    -- Cross-Cloud Tests (GKE via VPN) ------------------------------------
    # Replace <GKE_ILB_TRANSLATED_IP> with the translated ILB IP.
    # If GKE ILB real IP is 10.0.X.Y, the translated IP is 10.100.X.Y

    # From shared-public: reach GKE test service
    curl http://<GKE_ILB_TRANSLATED_IP>:80

    # From app-a-private: reach GKE test service via TGW -> VPN
    curl http://<GKE_ILB_TRANSLATED_IP>:80

    # From app-b-private: reach GKE test service via TGW -> VPN
    curl http://<GKE_ILB_TRANSLATED_IP>:80

  EOT
}

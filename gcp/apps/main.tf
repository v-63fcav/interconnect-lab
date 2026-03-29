# =============================================================================
# TEST APPLICATION — HTTP Service with Internal Load Balancer
# =============================================================================
# Deploys a simple nginx pod exposed via an Internal TCP Load Balancer (ILB).
# The ILB gets a private IP from the node subnet (10.0.x.x), which AWS
# reaches via the translated range (10.100.x.x) through the HA VPN tunnel.
#
# This is the target service for cross-cloud connectivity testing:
#   From AWS: curl http://10.100.<ILB_HOST_PART>:80
# =============================================================================

resource "kubernetes_namespace" "test" {
  metadata {
    name = "cross-cloud-test"
  }
}

resource "kubernetes_deployment" "test_app" {
  metadata {
    name      = "test-app"
    namespace = kubernetes_namespace.test.metadata[0].name
    labels = {
      app = "test-app"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "test-app"
      }
    }

    template {
      metadata {
        labels = {
          app = "test-app"
        }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:alpine"

          port {
            container_port = 80
          }

          volume_mount {
            name       = "html"
            mount_path = "/usr/share/nginx/html"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }
        }

        # Init container writes a custom index.html with connection metadata
        init_container {
          name  = "init-html"
          image = "busybox:1.36"
          command = [
            "sh", "-c",
            <<-EOT
            cat > /html/index.html <<'HTML'
            <h1>Cross-Cloud Test Service</h1>
            <p>You have successfully reached a GKE service from AWS via HA VPN!</p>
            <hr>
            <table>
              <tr><td><b>Cloud:</b></td><td>GCP (Google Kubernetes Engine)</td></tr>
              <tr><td><b>Cluster:</b></td><td>interconnect-lab-gke</td></tr>
              <tr><td><b>Namespace:</b></td><td>cross-cloud-test</td></tr>
              <tr><td><b>Service:</b></td><td>test-app (nginx)</td></tr>
              <tr><td><b>Connectivity:</b></td><td>AWS TGW → HA VPN → GCP NAT VM → ILB → Pod</td></tr>
            </table>
            <hr>
            <p><i>If you see this page, the multi-cloud VPN tunnel, NAT translation,
            and internal load balancing are all working correctly.</i></p>
            HTML
            EOT
          ]

          volume_mount {
            name       = "html"
            mount_path = "/html"
          }
        }

        volume {
          name = "html"
          empty_dir {}
        }
      }
    }
  }
}

# --- Internal Load Balancer Service ---
# The annotation networking.gke.io/load-balancer-type: "Internal" makes GKE
# provision a GCP Internal TCP Load Balancer instead of an external one.
# The ILB gets an IP from the node subnet (10.0.x.x).

resource "kubernetes_service" "test_app_ilb" {
  metadata {
    name      = "test-app-ilb"
    namespace = kubernetes_namespace.test.metadata[0].name
    annotations = {
      "networking.gke.io/load-balancer-type" = "Internal"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = "test-app"
    }

    port {
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }
  }
}

# Multi-Cloud Interconnect Lab (AWS + GCP)

A Terraform monorepo that deploys a complete multi-cloud networking lab connecting **AWS** (4 VPCs, Transit Gateway, PrivateLink) to **GCP** (GKE cluster) via **HA VPN** with **NAT translation** for overlapping CIDRs.

## Architecture

```
AWS (us-east-2)                                              GCP (us-west1)
┌──────────────────────────────────────┐                   ┌──────────────────────────────────────┐
│                                      │                   │                                      │
│  ┌──────────┐   ┌──────────┐        │                   │       interconnect-lab-vpc            │
│  │vpc-shared│   │vpc-app-a │        │                   │  Real:  10.0.0.0/16 (nodes)          │
│  │10.0/16   │   │10.1/16   │        │                   │         10.1.0.0/16 (pods)           │
│  │ public   │──▶│ public   │        │                   │         10.2.0.0/20 (services)       │
│  │ private  │   │ private  │ Peering│                   │                                      │
│  │ isolated │   │ isolated │        │                   │  ┌─────────┐  ┌──────────────────┐   │
│  └────┬─────┘   └────┬─────┘        │                   │  │   GKE   │  │    NAT VM        │   │
│       │              │              │                   │  │ Cluster │  │  (e2-micro)      │   │
│  ┌────┴──────────────┴────┐         │  4 IPSec Tunnels  │  │         │  │  DNAT+MASQ       │   │
│  │    Transit Gateway     │◄═══════════════════════════►│  │ test-app│  │  10.100→10.0     │   │
│  │    (hub & spoke)       │  BGP: 64512 ◄──► 65534     │  │  (ILB)  │  │  10.101→10.1     │   │
│  └────┬──────────────┬────┘         │                   │  └────┬────┘  │  10.102→10.2     │   │
│       │              │              │                   │       │       └────────┬─────────┘   │
│  ┌────┴─────┐  ┌─────┴────┐        │                   │       └───────────────┘              │
│  │vpc-app-b │  │vpc-vendor│        │                   │                                      │
│  │10.2/16   │  │10.3/16   │        │                   │  Cloud Router (ASN 65534)            │
│  │PrivateLink│  │ isolated │        │                   │  Advertises: 10.100/16, 10.101/16,  │
│  │ producer │──▶│ consumer │        │                   │              10.102/20               │
│  └──────────┘  └──────────┘        │                   │                                      │
│                                      │                   │  AWS sees GKE as: 10.100.x.x        │
└──────────────────────────────────────┘                   └──────────────────────────────────────┘
```

## The Overlapping CIDR Problem

Both clouds use the same IP ranges — this is common in real-world multi-cloud merges:

| Range | AWS Usage | GCP Usage | Overlap? |
|-------|-----------|-----------|----------|
| 10.0.0.0/16 | vpc-shared | GKE nodes | Yes |
| 10.1.0.0/16 | vpc-app-a | GKE pods | Yes |
| 10.2.0.0/16 | vpc-app-b | GKE services (/20) | Yes |
| 10.3.0.0/16 | vpc-vendor | — | No |

### Solution: GCP Yields via NAT Translation

GCP presents itself to AWS under **translated CIDRs** that don't collide. AWS keeps its real IPs unchanged.

| GCP Real CIDR | Translated (seen by AWS) |
|---------------|--------------------------|
| 10.0.0.0/16 (nodes) | **10.100.0.0/16** |
| 10.1.0.0/16 (pods) | **10.101.0.0/16** |
| 10.2.0.0/20 (services) | **10.102.0.0/20** |

**How it works:**
1. GCP Cloud Router advertises translated ranges (`10.100.x`, `10.101.x`, `10.102.x`) to AWS via BGP — never the real overlapping ranges
2. AWS TGW learns these routes and propagates them to all attached VPCs
3. AWS instances send traffic to `10.100.x.x` → TGW → VPN tunnel → GCP
4. In GCP, VPC routes direct `10.100.x.x` traffic to the **NAT VM**
5. NAT VM performs **DNAT** (`10.100.x.x` → `10.0.x.x`) + **MASQUERADE** (source → NAT VM IP)
6. Packet reaches the real GKE service; response flows back via conntrack

## Network Services Demonstrated

### AWS Side (Mirrored from aws-labs)

| Service | Description |
|---------|-------------|
| **Transit Gateway** | Hub-and-spoke connecting 3 VPCs (shared, app-a, app-b) + VPN to GCP |
| **VPC Peering** | Direct link shared↔app-a (demonstrates route priority: /16 peering wins over /8 TGW) |
| **VPC Endpoints** | S3 Gateway (free, all VPCs) + SSM/STS Interface (shared + vendor) |
| **PrivateLink** | NLB in app-b exposed to vendor via Endpoint Service (zero network connectivity) |
| **HA VPN** | 2 VPN connections (4 tunnels) with BGP to GCP Cloud Router |

### GCP Side (Mirrored from sl-gke)

| Service | Description |
|---------|-------------|
| **GKE Cluster** | Regional, private nodes, Workload Identity, REGULAR release channel |
| **HA VPN** | HA VPN Gateway with 4 tunnels to AWS TGW |
| **Cloud Router** | BGP (ASN 65534) with custom route advertisements (translated CIDRs) |
| **NAT VM** | e2-micro with iptables DNAT+MASQUERADE for CIDR translation |
| **Internal LB** | Exposes test-app privately via ILB (reachable from AWS as 10.100.x.x) |
| **Cloud NAT** | Outbound internet for private GKE nodes |

## Repo Structure

```
interconnect-lab/
├── aws/
│   ├── networking/          # Layer 1: VPCs, TGW, Peering, Endpoints, PrivateLink, VPN
│   │   ├── backend.tf
│   │   ├── data.tf
│   │   ├── iam.tf           # SSM Session Manager role
│   │   ├── locals.tf        # Subnet CIDR calculations
│   │   ├── outputs.tf       # VPC IDs, subnet IDs, VPN tunnel details
│   │   ├── privatelink.tf   # NLB + Endpoint Service + consumer endpoint
│   │   ├── providers.tf
│   │   ├── s3.tf            # Test bucket for Gateway Endpoint validation
│   │   ├── transit-gateway.tf  # TGW + 3 attachments + route table entries
│   │   ├── variables.tf     # CIDRs, flags, GCP VPN IPs
│   │   ├── versions.tf
│   │   ├── vpc-endpoints.tf # S3 Gateway + SSM/STS Interface endpoints
│   │   ├── vpc-peering.tf   # shared↔app-a direct peering
│   │   ├── vpc.tf           # 4 VPCs, subnets, IGWs, NATs, route tables
│   │   └── vpn.tf           # 2 Customer Gateways + 2 VPN connections (BGP)
│   └── compute/             # Layer 2: EC2 instances + Security Groups
│       ├── backend.tf
│       ├── data.tf           # AL2023 AMI lookup
│       ├── ec2.tf            # 6 instances + 4 SGs + PrivateLink attachment
│       ├── outputs.tf        # Instance IDs, IPs, test commands
│       ├── providers.tf
│       ├── remote-state.tf   # Reads networking outputs via S3 state
│       ├── variables.tf
│       └── versions.tf
├── gcp/
│   ├── infra/               # Layer 3: VPC, GKE, Firewall, VPN, NAT VM
│   │   ├── apis.tf          # Required GCP API enablement
│   │   ├── backend.tf
│   │   ├── firewall.tf      # RFC-1918 internal + health check rules
│   │   ├── gke-cluster.tf   # Cluster, node pool, SA, IAM
│   │   ├── nat-vm.tf        # NAT gateway VM + VPC routes for translated CIDRs
│   │   ├── outputs.tf       # Cluster info, VPN IPs, NAT VM IP
│   │   ├── variables.tf     # Project, CIDRs, VPN config, translated CIDRs
│   │   ├── versions.tf
│   │   ├── vpc.tf           # VPC, subnet, Cloud Router (BGP), Cloud NAT
│   │   └── vpn.tf           # HA VPN GW, external GW, tunnels, BGP peers
│   └── apps/                # Layer 4: Test application + Internal LB
│       ├── backend.tf
│       ├── main.tf          # nginx deployment + ILB Service
│       ├── outputs.tf       # ILB IP, translated IP, test command
│       ├── providers.tf     # Google + Kubernetes providers
│       ├── variables.tf
│       └── versions.tf
├── .github/
│   └── workflows/
│       ├── tf-deploy-aws.yml   # Deploy AWS: networking → compute
│       ├── tf-deploy-gcp.yml   # Deploy GCP: infra → apps
│       └── tf-destroy.yml      # Destroy all 4 layers (reverse order)
├── README.md
└── .gitignore
```

## Deploy Order

The VPN has a **chicken-and-egg dependency**: GCP needs AWS tunnel IPs, and AWS needs GCP gateway IPs. This requires 5 sequential applies across 4 layers:

```
Phase 1                Phase 2                Phase 3                Phase 4         Phase 5
┌────────────────┐     ┌────────────────┐     ┌────────────────┐     ┌──────────┐   ┌──────────┐
│ GCP infra      │────▶│ AWS networking │────▶│ GCP infra      │────▶│ AWS      │──▶│ GCP apps │
│ (VPN GW only)  │     │ (VPN + all)    │     │ (tunnels+BGP)  │     │ compute  │   │ (test    │
│                │     │                │     │                │     │ (EC2s)   │   │  app+ILB)│
│ Outputs:       │     │ Outputs:       │     │ BGP sessions   │     │          │   │          │
│ 2 GCP VPN IPs  │     │ 4 tunnel IPs   │     │ come up        │     │          │   │ Outputs: │
│                │     │ 4 PSKs         │     │ NAT VM starts  │     │          │   │ ILB IP   │
│                │     │ BGP addresses  │     │                │     │          │   │          │
└────────────────┘     └────────────────┘     └────────────────┘     └──────────┘   └──────────┘
```

### Step-by-Step Deploy Instructions

#### Prerequisites

- AWS CLI configured with credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
- GCP CLI configured (`gcloud auth application-default login`)
- Terraform >= 1.5 installed
- S3 bucket `ps-sl-state-bucket-cavi-2` exists (AWS state)
- GCS bucket `sl-gke-tf-state-cavi` exists (GCP state)

#### Phase 1 — GCP Infra (HA VPN Gateway Only)

```bash
cd gcp/infra
terraform init
terraform apply -var="create_vpn=true"

# Note the 2 HA VPN external IPs:
terraform output vpn_gateway_ips
# Example: ["34.157.100.1", "34.157.100.2"]
```

At this point, VPN tunnels are NOT created yet (aws_vpn_tunnels is empty). Only the HA VPN gateway and GKE cluster are provisioned.

#### Phase 2 — AWS Networking (Full Stack + VPN)

```bash
cd aws/networking
terraform init
terraform apply \
  -var="create_vpn=true" \
  -var='gcp_vpn_gateway_ips=["34.157.100.1","34.157.100.2"]'

# Extract tunnel details for GCP:
terraform output -json vpn_tunnel_details > /tmp/vpn_tunnels.json
# Review the 4 tunnel configs (outside_ip, psk, inside IPs, interface mapping)
```

#### Phase 3 — GCP Infra (Complete VPN + NAT VM)

Create a `gcp/infra/vpn-tunnels.auto.tfvars` file with the AWS tunnel details:

```hcl
# Example — replace with actual values from Phase 2 output
aws_vpn_tunnels = [
  {
    outside_ip       = "3.16.100.1"
    psk              = "abcdef1234567890abcdef1234567890"
    aws_inside_ip    = "169.254.10.1"
    gcp_inside_ip    = "169.254.10.2"
    vpn_gw_interface = 0
  },
  {
    outside_ip       = "3.16.100.2"
    psk              = "1234567890abcdef1234567890abcdef"
    aws_inside_ip    = "169.254.10.5"
    gcp_inside_ip    = "169.254.10.6"
    vpn_gw_interface = 0
  },
  {
    outside_ip       = "3.16.100.3"
    psk              = "abcdef0987654321abcdef0987654321"
    aws_inside_ip    = "169.254.10.9"
    gcp_inside_ip    = "169.254.10.10"
    vpn_gw_interface = 1
  },
  {
    outside_ip       = "3.16.100.4"
    psk              = "0987654321abcdef0987654321abcdef"
    aws_inside_ip    = "169.254.10.13"
    gcp_inside_ip    = "169.254.10.14"
    vpn_gw_interface = 1
  },
]
```

```bash
cd gcp/infra
terraform apply -var="create_vpn=true"

# Verify BGP sessions:
gcloud compute routers get-status interconnect-lab-router \
  --region=us-west1 --format="table(result.bgpPeerStatus[].name,result.bgpPeerStatus[].status)"
# All 4 peers should show "ESTABLISHED"
```

#### Phase 4 — AWS Compute (EC2 Instances)

```bash
cd aws/compute
terraform init
terraform apply -var="state_bucket=ps-sl-state-bucket-cavi-2"

# Get test commands:
terraform output test_commands
```

#### Phase 5 — GCP Apps (Test Service + ILB)

```bash
cd gcp/apps
terraform init
terraform apply

# Get the ILB IP and translated test command:
terraform output test_app_ilb_ip
# Example: "10.0.5.100"
# Translated IP for AWS: 10.100.5.100

terraform output cross_cloud_test_command
# Example: curl http://10.100.5.100:80
```

## Testing

### Cross-Cloud Connectivity (AWS → GKE)

From any AWS instance via SSM Session Manager:

```bash
# Connect to an instance
aws ssm start-session --target <instance-id>

# Test: reach GKE service from AWS via VPN
# Replace 10.100.X.Y with the translated ILB IP from Phase 5
curl http://10.100.X.Y:80
# Expected: HTML page saying "Cross-Cloud Test Service"
```

All 3 TGW-attached VPCs (shared, app-a, app-b) can reach GKE:

| From Instance | VPC | Path to GKE |
|--------------|-----|-------------|
| shared-public | vpc-shared | Instance → TGW → VPN → NAT VM → ILB → Pod |
| shared-isolated | vpc-shared | Instance → TGW → VPN → NAT VM → ILB → Pod |
| app-a-private | vpc-app-a | Instance → TGW → VPN → NAT VM → ILB → Pod |
| app-a-isolated | vpc-app-a | Instance → TGW → VPN → NAT VM → ILB → Pod |
| app-b-private | vpc-app-b | Instance → TGW → VPN → NAT VM → ILB → Pod |
| vendor-isolated | vpc-vendor | **Cannot reach** (no TGW, PrivateLink only) |

### AWS Internal Tests

```bash
# TGW: app-a → app-b (spoke-to-spoke)
ping -c 3 <app-b-private-ip>

# Peering: app-a → shared (direct, not via TGW)
traceroute <shared-public-private-ip>   # Should be 1 hop

# S3 Gateway Endpoint (from isolated subnet, no internet):
aws s3 ls s3://<test-bucket-name>

# PrivateLink (from vendor-isolated):
curl http://<privatelink-endpoint-dns>

# Isolation proof (from vendor-isolated — all should FAIL):
ping -c 2 -W 2 <shared-public-private-ip>   # Timeout
curl -s --connect-timeout 5 ifconfig.me       # Timeout
```

### Troubleshooting

**VPN tunnels not coming up:**
```bash
# AWS: check tunnel status
aws ec2 describe-vpn-connections \
  --filters Name=tag:Project,Values=interconnect-lab \
  --query 'VpnConnections[].VgwTelemetry[].{IP:OutsideIpAddress,Status:Status}'

# GCP: check tunnel status
gcloud compute vpn-tunnels list --filter="region:us-west1" --format="table(name,status,detailedStatus)"

# GCP: check BGP peer status
gcloud compute routers get-status interconnect-lab-router --region=us-west1
```

**NAT VM not translating:**
```bash
# SSH to NAT VM via IAP
gcloud compute ssh interconnect-lab-nat-gateway --zone=<zone> --tunnel-through-iap

# Check iptables rules
sudo iptables -t nat -L -n -v

# Check IP forwarding
sysctl net.ipv4.ip_forward

# Watch live traffic
sudo tcpdump -i eth0 'host 10.100.0.0/16' -n
```

**ILB not getting an IP:**
```bash
# Check the service status
kubectl get svc -n cross-cloud-test
# The EXTERNAL-IP column should show a 10.0.x.x IP (may take 1-2 minutes)
```

## Traffic Flow Detail

```
AWS app-a-private (10.1.2.x)
  │
  │ dst: 10.100.5.100:80 (translated GKE ILB)
  ▼
VPC Route: 10.0.0.0/8 → TGW
  │
  ▼
TGW Route: 10.100.0.0/16 → VPN attachment (BGP-learned)
  │
  ▼
IPSec Tunnel (encrypted, via internet backbone)
  │
  ▼
GCP Cloud Router (receives packet from VPN)
  │
  ▼
VPC Route: 10.100.0.0/16 → NAT VM (next-hop-instance, priority 100)
  │
  ▼
NAT VM iptables:
  PREROUTING: DNAT 10.100.5.100 → 10.0.5.100 (real ILB IP)
  POSTROUTING: MASQUERADE src → NAT VM IP (avoids overlap ambiguity)
  │
  ▼
GCP Internal Load Balancer (10.0.5.100:80)
  │
  ▼
GKE Pod (nginx, cross-cloud-test namespace)
  │
  │ Response follows reverse path via conntrack
  ▼
AWS app-a-private receives HTTP response
```

## Connectivity Matrix

| FROM ↓ \ TO → | shared | app-a | app-b | vendor | GKE (translated) |
|----------------|--------|-------|-------|--------|-------------------|
| **shared** | self | Peer | TGW | — | TGW→VPN→NAT |
| **app-a** | Peer | self | TGW | — | TGW→VPN→NAT |
| **app-b** | TGW | TGW | self | — | TGW→VPN→NAT |
| **vendor** | — | — | [PL] | self | — |
| **GKE** | — | — | — | — | self |

- **Peer** = VPC Peering (direct, /16 wins over /8 TGW route)
- **TGW** = Transit Gateway (hub-and-spoke)
- **[PL]** = PrivateLink (service-level only, port 80)
- **TGW→VPN→NAT** = Cross-cloud via HA VPN with CIDR translation
- **—** = No connectivity

## Destroy Order

**Always destroy in reverse layer order** to avoid orphaned resources:

```bash
# 1. GCP apps (removes K8s resources + ILB)
cd gcp/apps && terraform destroy

# 2. AWS compute (removes EC2 instances)
cd aws/compute && terraform destroy -var="state_bucket=ps-sl-state-bucket-cavi-2"

# 3. GCP infra (removes GKE, VPN, NAT VM, VPC)
cd gcp/infra && terraform destroy -var="create_vpn=true"

# 4. AWS networking (removes VPCs, TGW, VPN, endpoints)
cd aws/networking && terraform destroy -var="create_vpn=true" \
  -var='gcp_vpn_gateway_ips=["x.x.x.x","y.y.y.y"]'
```

> **Note:** GKE Internal Load Balancers create GCP forwarding rules that may take up to 60 seconds to delete. If `gcp/infra` destroy fails on the VPC, wait and retry.

## Cost Estimate

| Component | Qty | Cost/hr | Monthly (~730 hrs) |
|-----------|-----|---------|---------------------|
| AWS TGW attachments | 3 | $0.05 × 3 | $109.50 |
| AWS NAT Gateways | 3 | $0.045 × 3 | $98.55 |
| AWS VPN connections | 2 | $0.05 × 2 | $73.00 |
| AWS Interface Endpoints | 8 | $0.01 × 8 | $58.40 |
| AWS EC2 (t3.micro) | 6 | $0.01 × 6 | $43.80 |
| AWS NLB (PrivateLink) | 1 | $0.0225 | $16.43 |
| GCP GKE cluster | 1 | $0.10 | $73.00 |
| GCP HA VPN tunnels | 4 | $0.05 × 4 | $146.00 |
| GCP Node pool (e2-std-2) | 2-6 | $0.067 × 2 | $97.82 |
| GCP NAT VM (e2-micro) | 1 | $0.008 | $5.84 |
| GCP Cloud NAT | 1 | $0.045 | $32.85 |
| GCP ILB | 1 | $0.025 | $18.25 |
| **Total** | | **~$1.05/hr** | **~$773/mo** |

> **Cost saving:** Set `create_nat_gateways = false` on AWS and `create_vpn = false` on both sides when not testing cross-cloud. This drops cost to ~$400/mo. **Destroy everything when not in use.**

## CI/CD — GitHub Actions

Three workflows handle deploy and destroy. The VPN chicken-and-egg means deploy is split into per-cloud workflows (manual trigger between them), while destroy is unified.

| Workflow | Trigger | Jobs |
|----------|---------|------|
| `tf-deploy-aws.yml` | `workflow_dispatch` | networking → compute |
| `tf-deploy-gcp.yml` | `workflow_dispatch` | infra → apps |
| `tf-destroy.yml` | `workflow_dispatch` | gcp/apps → aws/compute → gcp/infra → aws/networking |

### Required Secrets

| Secret | Purpose |
|--------|---------|
| `AWS_ACCESS_KEY_ID` | AWS credentials |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials |
| `TF_API_TOKEN` | Terraform Cloud (setup-terraform action) |
| `TF_STATE_BUCKET` | S3 bucket for AWS remote state |
| `GCP_CREDENTIALS` | GCP Service Account JSON key |

### Deploy via CI/CD

Due to the VPN chicken-and-egg, full deploy requires manual intervention:

1. Run **Deploy GCP** workflow (creates GKE + HA VPN gateway)
2. Copy GCP VPN IPs → set as workflow input or `.tfvars`
3. Run **Deploy AWS** workflow (creates VPCs + VPN connections)
4. Copy AWS tunnel details → update GCP `.tfvars`
5. Re-run **Deploy GCP** workflow (completes VPN tunnels + NAT VM + apps)

For the initial VPN setup, local `terraform apply` with manual variable passing (as described in the deploy instructions above) is more practical. CI/CD is best suited for subsequent updates after the VPN is established.

### Destroy via CI/CD

Run the **Terraform Destroy** workflow — it destroys all 4 layers in reverse order automatically, including waiting for GKE load balancer cleanup.

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **GCP yields (not AWS)** | GCP Private NAT is cloud-native; AWS has no managed VPN NAT |
| **MASQUERADE (not NETMAP SNAT)** | Overlapping source IPs are ambiguous — MASQUERADE uses one unambiguous IP |
| **NAT VM (not GCP Private NAT)** | Private NAT only handles SNAT (outbound); DNAT requires a VM |
| **BGP (not static routes)** | Dynamic route exchange; TGW auto-propagates GCP routes to all VPCs |
| **4 tunnels (not 2)** | Full HA: 2 AWS connections × 2 tunnels each, across 2 GCP interfaces |
| **Monorepo (not separate repos)** | Keeps both sides versioned together; deploy order is documented |
| **Cloud Router custom adverts** | Per-peer `advertise_mode = CUSTOM` to avoid conflicting with Cloud NAT |

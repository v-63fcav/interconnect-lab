# Laboratório Multi-Cloud Interconnect (AWS + GCP)

Um monorepo Terraform que implanta um laboratório completo de networking multi-cloud conectando **AWS** (4 VPCs, Transit Gateway, PrivateLink) ao **GCP** (cluster GKE) via **HA VPN** com **tradução NAT** para CIDRs sobrepostos.

## Arquitetura

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

## O Problema de CIDRs Sobrepostos

Ambas as nuvens usam os mesmos ranges de IP — isso é comum em integrações multi-cloud no mundo real:

| Range | Uso na AWS | Uso no GCP | Sobreposição? |
|-------|-----------|-----------|---------------|
| 10.0.0.0/16 | vpc-shared | GKE nodes | Sim |
| 10.1.0.0/16 | vpc-app-a | GKE pods | Sim |
| 10.2.0.0/16 | vpc-app-b | GKE services (/20) | Sim |
| 10.3.0.0/16 | vpc-vendor | — | Não |

### Solução: GCP cede via tradução NAT

O GCP se apresenta para a AWS sob **CIDRs traduzidos** que não colidem. A AWS mantém seus IPs reais inalterados.

| CIDR Real GCP | Traduzido (visto pela AWS) |
|---------------|--------------------------|
| 10.0.0.0/16 (nodes) | **10.100.0.0/16** |
| 10.1.0.0/16 (pods) | **10.101.0.0/16** |
| 10.2.0.0/20 (services) | **10.102.0.0/20** |

**Como funciona:**
1. O Cloud Router do GCP anuncia os ranges traduzidos (`10.100.x`, `10.101.x`, `10.102.x`) para a AWS via BGP — nunca os ranges reais sobrepostos
2. O TGW da AWS aprende essas rotas e as propaga para todas as VPCs attached
3. Instâncias AWS enviam tráfego para `10.100.x.x` → TGW → VPN tunnel → GCP
4. No GCP, rotas de VPC direcionam o tráfego `10.100.x.x` para a **NAT VM**
5. A NAT VM faz **DNAT** (`10.100.x.x` → `10.0.x.x`) + **MASQUERADE** (origem → IP da NAT VM)
6. O pacote alcança o serviço GKE real; a resposta volta via conntrack

## Serviços de Rede Demonstrados

### Lado AWS (Espelhado do aws-labs)

| Serviço | Descrição |
|---------|-----------|
| **Transit Gateway** | Hub-and-spoke conectando 3 VPCs (shared, app-a, app-b) + VPN para GCP |
| **VPC Peering** | Link direto shared↔app-a (demonstra prioridade de rotas: /16 peering vence /8 TGW) |
| **VPC Endpoints** | S3 Gateway (gratuito, todas as VPCs) + SSM/STS Interface (shared + vendor) |
| **PrivateLink** | NLB na app-b exposto para vendor via Endpoint Service (zero conectividade de rede) |
| **HA VPN** | 2 conexões VPN (4 tunnels) com BGP para o Cloud Router do GCP |

### Lado GCP (Espelhado do sl-gke)

| Serviço | Descrição |
|---------|-----------|
| **GKE Cluster** | Regional, nodes privados, Workload Identity, release channel REGULAR |
| **HA VPN** | HA VPN Gateway com 4 tunnels para o TGW da AWS |
| **Cloud Router** | BGP (ASN 65534) com anúncios de rotas customizados (CIDRs traduzidos) |
| **NAT VM** | e2-micro com iptables DNAT+MASQUERADE para tradução de CIDRs |
| **Internal LB** | Expõe test-app de forma privada via ILB (acessível da AWS como 10.100.x.x) |
| **Cloud NAT** | Internet de saída para nodes privados do GKE |

## Estrutura do Repositório

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

## Ordem de Deploy

A VPN tem uma **dependência chicken-and-egg**: o GCP precisa dos IPs dos tunnels da AWS, e a AWS precisa dos IPs do gateway do GCP. Isso requer 5 applies sequenciais em 4 camadas:

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

### Instruções de Deploy Passo a Passo

#### Pré-requisitos

- AWS CLI configurado com credenciais (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
- GCP CLI configurado (`gcloud auth application-default login`)
- Terraform >= 1.5 instalado
- Bucket S3 `ps-sl-state-bucket-cavi-2` existente (state da AWS)
- Bucket GCS `sl-gke-tf-state-cavi` existente (state do GCP)

#### Fase 1 — GCP Infra (Apenas HA VPN Gateway)

```bash
cd gcp/infra
terraform init
terraform apply -var="create_vpn=true"

# Note the 2 HA VPN external IPs:
terraform output vpn_gateway_ips
# Example: ["34.157.100.1", "34.157.100.2"]
```

Neste ponto, os VPN tunnels ainda NÃO estão criados (aws_vpn_tunnels está vazio). Apenas o HA VPN gateway e o cluster GKE estão provisionados.

#### Fase 2 — AWS Networking (Stack Completa + VPN)

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

#### Fase 3 — GCP Infra (VPN Completa + NAT VM)

Crie um arquivo `gcp/infra/vpn-tunnels.auto.tfvars` com os detalhes dos tunnels da AWS:

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

#### Fase 4 — AWS Compute (Instâncias EC2)

```bash
cd aws/compute
terraform init
terraform apply -var="state_bucket=ps-sl-state-bucket-cavi-2"

# Get test commands:
terraform output test_commands
```

#### Fase 5 — GCP Apps (Serviço de Teste + ILB)

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

## Guia de Testes — 26 Cenários

Após o deploy, execute `terraform output test_commands` em `aws/compute` para comandos prontos para colar.

> **Notação:** `<shared-public-ip>` significa o IP privado da instância shared-public. Obtenha todos os IPs com `terraform output private_ips` na camada compute. `<GKE_ILB_IP>` é o IP traduzido do ILB do output de `gcp/apps` (ex: `10.100.5.100`).

---

### Grupo A: Conectividade com a Internet

#### A1. Public Subnet — Internet de Saída

```
shared-public (10.0.1.x) --> IGW (1:1 NAT) --> Internet
       route: 0.0.0.0/0 -> igw
```

**O que prova:** Public subnets têm internet bidirecional via Internet Gateway.

```bash
# From shared-public:
curl -s ifconfig.me
# Expected: returns the instance's public IP address
```

**Como funciona:** A route table da public subnet tem `0.0.0.0/0 -> IGW`. O IGW faz NAT stateless 1:1: IP privado para IP público na saída, invertido para respostas.

#### A2. Public Subnet — Internet de Entrada

```
Internet --> IGW (pub->priv NAT) --> SG :80 --> shared-public (10.0.1.x)
```

**O que prova:** Instâncias com IPs públicos recebem conexões de entrada se o security group permitir.

```bash
# From your local machine:
curl http://<shared-public-public-ip>
# Expected: HTML response from the Apache server
```

#### A3. Private Subnet — Apenas Saída

```
app-a-private (10.1.2.x) --> NAT GW (EIP) --> IGW --> Internet
       route: 0.0.0.0/0 -> nat-gw
Internet --> NAT GW --> (no inbound mapping) --> BLOCKED
```

**O que prova:** Private subnets alcançam a internet na saída (via NAT Gateway) mas não podem receber conexões de entrada.

```bash
# From app-a-private:
curl -s ifconfig.me
# Expected: returns the NAT Gateway's Elastic IP (NOT the instance's IP)
```

**Como funciona:** O NAT Gateway faz PAT (port address translation) stateful. Ele rastreia conexões de saída e mapeia respostas de volta. Pacotes de entrada não solicitados não têm mapeamento e são descartados.

#### A4. Isolated Subnet — Zero Internet

```
shared-isolated (10.0.3.x) --> route table: no 0.0.0.0/0 --> DROPPED
  but cross-VPC works:
shared-isolated (10.0.3.x) --> TGW (10.0.0.0/8) --> app-b-private
```

**O que prova:** Isolated subnets têm zero acesso à internet — literalmente não existe rota.

```bash
# From shared-isolated:
curl -s --connect-timeout 5 ifconfig.me
# Expected: timeout after 5 seconds

# But internal cross-VPC still works:
ping -c 2 <app-b-private-ip>
# Expected: success via TGW
```

---

### Grupo B: Transit Gateway

#### B1. Hub para Spoke (shared -> app-b)

```
shared-public (10.0.1.x) --> TGW --> vpc-app-b attachment --> app-b-private (10.2.2.x)
       route: 10.0.0.0/8 -> tgw     propagated: 10.2.0.0/16
```

**O que prova:** O TGW habilita conectividade hub-and-spoke.

```bash
# From shared-public:
ping -c 3 <app-b-private-ip>
# Expected: success via TGW
```

**Como rastrear:** Use `traceroute` para ver o hop do TGW:

```bash
# From shared-public:
traceroute -n <app-b-private-ip>
# Expected: 1st hop is the TGW ENI, 2nd hop is the destination
# TGW appears as a single hop in traceroute (it's a managed service)
```

#### B2. Spoke para Spoke (app-a <-> app-b)

```
app-a-private (10.1.2.x) --> TGW --> vpc-app-b attachment --> app-b-private (10.2.2.x)
       No direct peering -- TGW provides transitive routing
```

**O que prova:** O TGW fornece roteamento transitivo — spoke A alcança spoke B através do hub, sem peering direto.

```bash
# From app-a-private:
ping -c 3 <app-b-private-ip>
# Expected: success — app-a -> TGW -> app-b

# From app-b-private (reverse):
ping -c 3 <app-a-private-ip>
# Expected: success — bidirectional
```

**Como rastrear a route table do TGW:**

```bash
# List all TGW route table entries (shows VPC + VPN propagated routes):
TGW_ID=$(aws ec2 describe-transit-gateways \
  --filters Name=tag:Project,Values=interconnect-lab \
  --query 'TransitGateways[0].TransitGatewayId' --output text)

RT_ID=$(aws ec2 describe-transit-gateway-route-tables \
  --filters Name=transit-gateway-id,Values=$TGW_ID \
  --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text)

aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id $RT_ID \
  --filters Name=state,Values=active \
  --query 'Routes[].{CIDR:DestinationCidrBlock,Type:Type,Attachment:TransitGatewayAttachments[0].ResourceType}' \
  --output table
# Expected: 10.0.0.0/16 (vpc), 10.1.0.0/16 (vpc), 10.2.0.0/16 (vpc),
#           10.100.0.0/16 (vpn), 10.101.0.0/16 (vpn), 10.102.0.0/20 (vpn)
```

#### B3. Cross-Tier via TGW (isolated -> remote private)

```
app-a-isolated (10.1.3.x) --> TGW --> vpc-app-b --> app-b-private (10.2.2.x)
       isolated subnet                              private subnet
```

**O que prova:** O TGW roteia entre VPCs independentemente do tier da subnet.

```bash
# From app-a-isolated:
ping -c 3 <app-b-private-ip>
# Expected: success — TGW doesn't care about subnet tier
```

---

### Grupo C: VPC Peering

#### C1. Prioridade da Rota Peering sobre TGW

```
app-a -> shared:  10.0.0.0/16 -> Peering   WINS (longest prefix)
                   10.0.0.0/8  -> TGW       less specific, ignored

app-a -> app-b:   10.0.0.0/8  -> TGW       only matching route (no peering with app-b)
```

**O que prova:** Quando uma rota de peering (/16) e uma rota de TGW (/8) correspondem, a rota mais específica vence (longest prefix match).

```bash
# From app-a-private:
traceroute -n <shared-public-ip>
# Expected: 1 hop (direct via peering — no TGW in path)

# Compare with a TGW-only destination:
traceroute -n <app-b-private-ip>
# Expected: 2 hops (via TGW)
```

**Como verificar qual rota está ativa:**

```bash
# Show the VPC route table for app-a-private's subnet:
SUBNET_ID=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=interconnect-lab-app-a-private \
  --query 'Reservations[0].Instances[0].SubnetId' --output text)

RT_ID=$(aws ec2 describe-route-tables \
  --filters Name=association.subnet-id,Values=$SUBNET_ID \
  --query 'RouteTables[0].RouteTableId' --output text)

aws ec2 describe-route-tables --route-table-ids $RT_ID \
  --query 'RouteTables[0].Routes[?State==`active`].{Dest:DestinationCidrBlock,Target:GatewayId||VpcPeeringConnectionId||TransitGatewayId}' \
  --output table
# You'll see both 10.0.0.0/8 -> tgw AND 10.0.0.0/16 -> pcx
# The /16 peering route wins for shared VPC destinations
```

#### C2. Peering Bidirecional

```
shared-public (10.0.1.x) <---- VPC Peering ----> app-a-private (10.1.2.x)
     route: 10.1.0.0/16 -> pcx         route: 10.0.0.0/16 -> pcx
```

**O que prova:** VPC Peering requer entradas de rota em AMBOS os lados.

```bash
# Both directions should work:
# From shared-public:
ping -c 3 <app-a-private-ip>    # Success via peering

# From app-a-private:
ping -c 3 <shared-public-ip>    # Success via peering
```

---

### Grupo D: VPC Endpoints

#### D1. S3 Gateway Endpoint (de Isolated Subnet)

```
shared-isolated (10.0.3.x) --> route: pl-xxx -> vpce --> S3 (AWS backbone)
       no internet              Gateway Endpoint          FREE
```

**O que prova:** S3 Gateway Endpoints permitem acesso ao S3 de subnets com zero internet.

```bash
# From shared-isolated:
aws s3 ls s3://<test-bucket-name>
# Expected: lists the test.txt file

aws s3 cp s3://<test-bucket-name>/test.txt -
# Expected: displays the success message
```

**Como rastrear:** Verifique que a rota do prefix list está presente:

```bash
# From shared-isolated:
# Check that the route table has the S3 prefix list entry:
ip route show
# You'll see entries for local, TGW (10.0.0.0/8), and the S3 prefix list
# The pl-xxx -> vpce entry routes S3 traffic to the endpoint
```

#### D2. SSM Interface Endpoint (Private DNS)

```
shared-isolated --> DNS: ssm.us-east-2.amazonaws.com -> 10.0.3.x (private!)
                   --> ENI (Interface Endpoint) --> SSM API (AWS backbone)
       without endpoint: ssm.us-east-2.amazonaws.com -> 52.x.x.x (public) -> BLOCKED
```

**O que prova:** Interface Endpoints criam uma ENI privada, e Private DNS reescreve o hostname público para o IP privado.

```bash
# From shared-isolated:
nslookup ssm.us-east-2.amazonaws.com
# Expected: resolves to 10.0.3.x (private IP in the isolated subnet)
# WITHOUT the endpoint, this would resolve to a public IP

# The fact that SSM session works on this instance (no internet!) is proof
```

#### D3. SSM Endpoints Centralizados via TGW

```
app-a-isolated --> Peering/TGW --> vpc-shared --> ENI (10.0.3.x) --> SSM API
       no local SSM endpoints       has SSM Interface Endpoints
```

**O que prova:** Você pode centralizar Interface Endpoints em uma VPC compartilhada e rotear de outras VPCs via TGW/peering.

```bash
# From app-a-isolated (has NO local SSM endpoints):
# If SSM session works, traffic flows: app-a -> peering -> shared -> SSM endpoint
aws ssm start-session --target <app-a-isolated-id>
```

---

### Grupo E: PrivateLink

#### E1. Consumo de Serviço via PrivateLink

```
PRODUCER (vpc-app-b)                          CONSUMER (vpc-vendor)
app-b-private:80 <-- NLB <-- Endpoint Svc <-- AWS backbone <-- ENI (10.3.1.x) <-- vendor-isolated
                              vpce-svc-xxx                      vpce-xxx
       vendor never sees app-b IPs -- only the local ENI
```

**O que prova:** Uma VPC totalmente isolada (sem TGW, sem peering, sem internet) pode acessar um serviço específico via PrivateLink.

```bash
# From vendor-isolated:
curl http://<privatelink-endpoint-dns>
# Expected: HTML from app-b's HTTP server:
#   "PrivateLink Service — You are accessing this service from vpc-app-b..."
```

**Como rastrear o caminho do PrivateLink:**

```bash
# From vendor-isolated — verify the ENI exists:
# The PrivateLink endpoint creates an ENI in the vendor subnet
ip addr show
# You'll see eth0 with 10.3.1.x — that's the instance
# The PrivateLink ENI is a separate resource (not on this instance),
# but traffic to the endpoint DNS resolves to an IP in 10.3.1.0/24

nslookup <privatelink-endpoint-dns>
# Expected: resolves to a 10.3.1.x IP (the PrivateLink ENI)
```

#### E2. Prova de Isolamento do PrivateLink

```
vendor-isolated attempts:
  -> shared (10.0.x.x)    no TGW, no peering, no route   BLOCKED
  -> app-a  (10.1.x.x)    no TGW, no peering, no route   BLOCKED
  -> app-b  (10.2.x.x)    PrivateLink != network access   BLOCKED
  -> internet              no IGW, no NAT                  BLOCKED
  -> app-b:80 via PL ENI  only this works                 OK
```

**O que prova:** PrivateLink é acesso a nível de serviço, NÃO a nível de rede. O vendor alcança APENAS a porta exposta.

```bash
# From vendor-isolated — all should FAIL:
ping -c 2 -W 2 <shared-public-ip>      # Timeout (no route)
ping -c 2 -W 2 <app-a-private-ip>      # Timeout (no route)
ping -c 2 -W 2 <app-b-private-ip>      # Timeout (PrivateLink != network)
curl -s --connect-timeout 5 ifconfig.me  # Timeout (no internet)

# Only this works:
curl http://<privatelink-endpoint-dns>   # Success (PrivateLink)
```

---

### Grupo F: Infraestrutura HA VPN

#### F1. Status dos VPN Tunnels

```
AWS TGW Attachments:
  |- vpc-shared     (type: vpc)     UP
  |- vpc-app-a      (type: vpc)     UP
  |- vpc-app-b      (type: vpc)     UP
  |- vpn-conn-0     (type: vpn)     UP (2 tunnels)
  '- vpn-conn-1     (type: vpn)     UP (2 tunnels)
```

**O que prova:** Os VPN tunnels de HA VPN entre AWS e GCP estão estabelecidos com roteamento BGP.

```bash
# AWS: check VPN tunnel status
aws ec2 describe-vpn-connections \
  --filters Name=tag:Project,Values=interconnect-lab \
  --query 'VpnConnections[].VgwTelemetry[].{IP:OutsideIpAddress,Status:Status,StatusMsg:StatusMessage}' \
  --output table
# Expected: 4 tunnels with Status: UP

# AWS: check TGW attachments (VPN alongside VPC attachments)
aws ec2 describe-transit-gateway-attachments \
  --filters Name=transit-gateway-id,Values=$TGW_ID \
  --query 'TransitGatewayAttachments[].{Type:ResourceType,State:State,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table
# Expected: 3x vpc (available) + 2x vpn (available)
```

```bash
# GCP: check tunnel status
gcloud compute vpn-tunnels list \
  --filter="region:us-west1" \
  --format="table(name,status,detailedStatus)"
# Expected: 4 tunnels with status: ESTABLISHED

# GCP: check BGP session status
gcloud compute routers get-status interconnect-lab-router \
  --region=us-west1 \
  --format="table(result.bgpPeerStatus[].name,result.bgpPeerStatus[].status,result.bgpPeerStatus[].numLearnedRoutes)"
# Expected: 4 peers with status: ESTABLISHED, numLearnedRoutes > 0
```

#### F2. Troca de Rotas BGP

```
AWS TGW learns from GCP:              GCP Cloud Router learns from AWS:
  10.100.0.0/16 -> vpn attachment       10.0.0.0/16 -> via BGP (shadowed by local)
  10.101.0.0/16 -> vpn attachment       10.1.0.0/16 -> via BGP (shadowed by local)
  10.102.0.0/20 -> vpn attachment       10.2.0.0/16 -> via BGP (shadowed by local)

GCP Cloud Router advertises (custom):
  10.100.0.0/16, 10.101.0.0/16, 10.102.0.0/20  (translated, not real)
```

**O que prova:** O BGP troca rotas dinamicamente. O GCP anuncia apenas CIDRs traduzidos; o TGW da AWS os auto-propaga.

```bash
# AWS: verify TGW learned the GCP translated routes
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id $RT_ID \
  --filters Name=type,Values=propagated Name=state,Values=active \
  --query 'Routes[?contains(DestinationCidrBlock,`10.10`)].{CIDR:DestinationCidrBlock,Type:Type}' \
  --output table
# Expected:
#   10.100.0.0/16  propagated  (GCP nodes, translated)
#   10.101.0.0/16  propagated  (GCP pods, translated)
#   10.102.0.0/20  propagated  (GCP services, translated)
```

```bash
# GCP: verify Cloud Router is advertising translated CIDRs
gcloud compute routers get-status interconnect-lab-router \
  --region=us-west1 \
  --format="yaml(result.bestRoutes)"
# Shows the advertised routes (10.100.x, 10.101.x, 10.102.x)

# GCP: verify routes learned from AWS (will be shadowed by local)
gcloud compute routers get-status interconnect-lab-router \
  --region=us-west1 \
  --format="yaml(result.bgpPeerStatus[].advertisedRoutes,result.bgpPeerStatus[].numLearnedRoutes)"
```

#### F3. Saúde da NAT VM

```
NAT VM (interconnect-lab-nat-gateway):
  can_ip_forward: true
  iptables PREROUTING:  DNAT 10.100.x -> 10.0.x, 10.101.x -> 10.1.x, 10.102.x -> 10.2.x
  iptables POSTROUTING: MASQUERADE (src -> NAT VM IP)
  VPC routes: 10.100/16, 10.101/16, 10.102/20 -> next-hop: NAT VM
```

**O que prova:** A NAT VM está corretamente configurada para tradução de CIDRs.

```bash
# SSH to NAT VM via IAP
gcloud compute ssh interconnect-lab-nat-gateway \
  --zone=$(gcloud compute instances list --filter="name=interconnect-lab-nat-gateway" --format="value(zone)") \
  --tunnel-through-iap

# Check IP forwarding is enabled
sysctl net.ipv4.ip_forward
# Expected: net.ipv4.ip_forward = 1

# Check iptables DNAT rules
sudo iptables -t nat -L PREROUTING -n -v
# Expected: 3 NETMAP rules:
#   10.100.0.0/16 -> 10.0.0.0/16
#   10.101.0.0/16 -> 10.1.0.0/16
#   10.102.0.0/20 -> 10.2.0.0/20

# Check MASQUERADE rule
sudo iptables -t nat -L POSTROUTING -n -v
# Expected: MASQUERADE on eth0

# Check conntrack entries (shows active translated connections)
sudo conntrack -L 2>/dev/null | head -20
# After a cross-cloud test, you'll see entries mapping 10.100.x -> 10.0.x
```

**Como verificar se as rotas VPC apontam para a NAT VM:**

```bash
# From outside the NAT VM:
gcloud compute routes list --filter="network=interconnect-lab-vpc AND destRange:10.100" \
  --format="table(name,destRange,nextHopInstance)"
# Expected: 3 routes pointing to interconnect-lab-nat-gateway
```

---

### Grupo G: Conectividade Cross-Cloud (AWS -> GKE)

#### G1. Hub para GKE (shared -> serviço GKE)

```
shared-public (10.0.1.x) --> TGW --> VPN tunnel --> Cloud Router
  --> NAT VM (DNAT 10.100.x->10.0.x, MASQ) --> ILB (10.0.x.x) --> GKE Pod
       route: 10.0.0.0/8 -> tgw     TGW route: 10.100.0.0/16 -> vpn (BGP)
```

**O que prova:** A VPC hub da AWS (shared) alcança um serviço GKE pelo caminho completo: TGW -> VPN -> NAT -> ILB -> Pod.

```bash
# From shared-public:
curl -s http://<GKE_ILB_IP>:80
# Expected: HTML saying "Cross-Cloud Test Service" with GKE metadata

# Measure latency (includes VPN + NAT overhead):
curl -o /dev/null -s -w "Total: %{time_total}s\nConnect: %{time_connect}s\nTTFB: %{time_starttransfer}s\n" http://<GKE_ILB_IP>:80
# Expected: total ~50-150ms (us-east-2 -> us-west1 cross-region)
```

#### G2. Spoke para GKE (app-a -> serviço GKE)

```
app-a-private (10.1.2.x) --> TGW --> VPN --> NAT VM --> ILB --> GKE Pod
       route: 10.0.0.0/8 -> tgw     same path as shared
```

**O que prova:** VPCs spoke attached ao TGW também alcançam o GKE — rotas propagadas via BGP estão disponíveis para todos os attachments.

```bash
# From app-a-private:
curl -s http://<GKE_ILB_IP>:80
# Expected: same HTML response — proves spoke VPCs reach GKE via TGW -> VPN
```

#### G3. VPC Somente-PrivateLink Não Alcança GKE

```
vendor-isolated (10.3.1.x) --> no TGW attachment --> no route to 10.100.x --> BLOCKED
       no TGW, no VPN, no peering -- only PrivateLink to app-b
```

**O que prova:** O caminho VPN requer participação no TGW. A vpc-vendor não tem TGW attachment, então não alcança o GKE mesmo com a VPN existindo.

```bash
# From vendor-isolated:
curl -s --connect-timeout 5 http://<GKE_ILB_IP>:80
# Expected: timeout — vendor has no route to 10.100.x.x

# But PrivateLink to AWS still works:
curl http://<privatelink-endpoint-dns>
# Expected: success — PrivateLink is independent of TGW/VPN
```

#### G4. Cross-Cloud de Múltiplos Tiers de Subnet

```
shared-public   (public)   --> TGW --> VPN --> GKE   OK
shared-isolated (isolated) --> TGW --> VPN --> GKE   OK
app-a-private   (private)  --> TGW --> VPN --> GKE   OK
app-a-isolated  (isolated) --> TGW --> VPN --> GKE   OK
app-b-private   (private)  --> TGW --> VPN --> GKE   OK
```

**O que prova:** A conectividade cross-cloud funciona de todo tier de subnet — public, private e isolated. A rota `10.0.0.0/8 -> TGW` existe em todas as route tables.

```bash
# Test from each instance type:
# From shared-isolated (no internet, but cross-cloud works!):
curl -s http://<GKE_ILB_IP>:80
# Expected: success — isolated subnet has TGW route, not internet route

# From app-a-isolated:
curl -s http://<GKE_ILB_IP>:80
# Expected: success — same reason
```

**Insight principal:** Isolated subnets têm zero internet mas conectividade cross-cloud completa. A rota `10.0.0.0/8 -> TGW` lida tanto com destinos cross-VPC (10.0-3.x) quanto cross-cloud (10.100.x).

---

### Grupo H: Rastreamento de Tráfego & Observabilidade

#### H1. Rastreamento de Pacote End-to-End (AWS -> GKE)

**O que prova:** Você pode observar o pacote em cada hop no caminho cross-cloud.

**Passo 1 — Observe o tráfego na NAT VM** (execute PRIMEIRO, em um terminal separado):

```bash
# SSH to NAT VM:
gcloud compute ssh interconnect-lab-nat-gateway --zone=<zone> --tunnel-through-iap

# Watch packets being translated in real-time:
sudo tcpdump -i eth0 -n 'net 10.100.0.0/16 or net 10.101.0.0/16 or net 10.102.0.0/16' -e
# This captures packets BEFORE DNAT (arriving with 10.100.x destination)
```

**Passo 2 — Envie uma requisição da AWS** (em outro terminal):

```bash
# From shared-public:
curl -s http://<GKE_ILB_IP>:80
```

**Passo 3 — Observe a saída do tcpdump:**

```
# Expected tcpdump on NAT VM:
# Inbound (pre-DNAT): src=10.0.1.x dst=10.100.5.100 -> DNAT -> dst becomes 10.0.5.100
# Response (post-MASQ): src=10.0.5.100 dst=<NAT_VM_IP> -> reverse NAT -> src becomes 10.100.5.100

# You'll see pairs of packets:
#   IN:  10.0.1.x > 10.100.5.100: TCP SYN
#   OUT: 10.100.5.100 > 10.0.1.x: TCP SYN-ACK
```

**Passo 4 — Verifique entradas do conntrack:**

```bash
# On the NAT VM, after the curl:
sudo conntrack -L -n 2>/dev/null | grep 10.100
# Expected: conntrack entry showing the NAT mapping:
#   tcp 6 ... src=10.0.1.x dst=10.100.5.100 sport=xxxxx dport=80
#                           src=10.0.5.100 dst=<NAT_VM_IP> sport=80 dport=xxxxx
```

#### H2. Contadores de Tráfego dos VPN Tunnels

**O que prova:** Você pode ver o volume de tráfego cruzando os VPN tunnels de ambos os consoles de nuvem.

```bash
# AWS: check bytes in/out per tunnel
aws ec2 describe-vpn-connections \
  --filters Name=tag:Project,Values=interconnect-lab \
  --query 'VpnConnections[].VgwTelemetry[].{OutsideIP:OutsideIpAddress,Status:Status,AcceptedRoutes:AcceptedRouteCount}' \
  --output table

# GCP: check tunnel traffic stats
gcloud compute vpn-tunnels describe interconnect-lab-to-aws-tunnel-0 \
  --region=us-west1 \
  --format="yaml(status,detailedStatus,peerIp)"

# GCP: check Cloud Router learned routes count (proves BGP exchange)
gcloud compute routers get-status interconnect-lab-router --region=us-west1 \
  --format="table(result.bgpPeerStatus[].name,result.bgpPeerStatus[].status,result.bgpPeerStatus[].numLearnedRoutes)"
```

#### H3. Contadores de Tradução NAT

**O que prova:** Contadores do iptables mostram exatamente quantos pacotes/bytes foram traduzidos.

```bash
# On the NAT VM:
sudo iptables -t nat -L PREROUTING -n -v --line-numbers
# Expected output:
# num  pkts bytes target   prot opt in  out  source     destination
# 1    42   2520  NETMAP   all  --  *   *    0.0.0.0/0  10.100.0.0/16  to:10.0.0.0/16
# 2    0    0     NETMAP   all  --  *   *    0.0.0.0/0  10.101.0.0/16  to:10.1.0.0/16
# 3    0    0     NETMAP   all  --  *   *    0.0.0.0/0  10.102.0.0/20  to:10.2.0.0/20
#
# The pkts/bytes columns show traffic hitting each DNAT rule.
# Rule 1 (nodes) will have the most traffic (ILB is in the node subnet).
# Rules 2-3 (pods/services) will be zero unless you address pods/services directly.

sudo iptables -t nat -L POSTROUTING -n -v --line-numbers
# Shows MASQUERADE packet counts — should match PREROUTING
```

#### H4. Observação no Nível do Pod GKE

**O que prova:** Você pode verificar que a requisição chegou ao pod GKE e ver o IP de origem (NAT VM).

```bash
# Get the pod name:
kubectl get pods -n cross-cloud-test -l app=test-app

# Check nginx access logs (shows who connected):
kubectl logs -n cross-cloud-test -l app=test-app --tail=20
# Expected: access log entries with source IP = NAT VM's internal IP (10.0.x.x)
# NOT the AWS instance IP — MASQUERADE changed the source

# Watch logs in real-time while sending requests from AWS:
kubectl logs -n cross-cloud-test -l app=test-app -f
# Then curl from AWS — you'll see the request appear
```

#### H5. AWS VPC Flow Logs (Opcional — Rastreamento Extra)

**O que prova:** VPC Flow Logs capturam metadados de pacotes no nível da ENI, permitindo rastrear tráfego entrando/saindo do TGW.

> Nota: VPC Flow Logs não são implantados por padrão (geram custos no CloudWatch). Habilite manualmente para debugging profundo.

```bash
# Enable flow logs on the TGW attachment subnet (one-time):
aws ec2 create-flow-logs \
  --resource-type VPC \
  --resource-ids <vpc-shared-id> \
  --traffic-type ALL \
  --log-destination-type cloud-watch-logs \
  --log-group-name /interconnect-lab/flow-logs

# After sending cross-cloud traffic, query the logs:
aws logs filter-log-events \
  --log-group-name /interconnect-lab/flow-logs \
  --filter-pattern "10.100" \
  --start-time $(date -d '5 minutes ago' +%s000)
# Expected: ACCEPT entries showing traffic to 10.100.x.x leaving the VPC toward TGW
```

---

### Solução de Problemas

**VPN tunnels não subindo:**
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

**NAT VM não traduzindo:**
```bash
# SSH to NAT VM via IAP
gcloud compute ssh interconnect-lab-nat-gateway --zone=<zone> --tunnel-through-iap

# Check iptables rules
sudo iptables -t nat -L -n -v

# Check IP forwarding
sysctl net.ipv4.ip_forward

# Watch live traffic
sudo tcpdump -i eth0 -n 'net 10.100.0.0/16'
```

**ILB não obtendo IP:**
```bash
# Check the service status
kubectl get svc -n cross-cloud-test
# The EXTERNAL-IP column should show a 10.0.x.x IP (may take 1-2 minutes)
```

**Cross-cloud curl dá timeout mas VPN está UP:**
```bash
# Check VPC routes for the translated CIDR on GCP:
gcloud compute routes list --filter="network=interconnect-lab-vpc AND destRange:10.100"
# If no routes: NAT VM may not have been created (create_vpn=false?)

# Check NAT VM is running:
gcloud compute instances describe interconnect-lab-nat-gateway \
  --zone=<zone> --format="value(status)"
# Expected: RUNNING
```

## Matriz de Conectividade

| DE ↓ \ PARA → | shared | app-a | app-b | vendor | GKE (traduzido) |
|----------------|--------|-------|-------|--------|-------------------|
| **shared** | self | Peer | TGW | — | TGW→VPN→NAT |
| **app-a** | Peer | self | TGW | — | TGW→VPN→NAT |
| **app-b** | TGW | TGW | self | — | TGW→VPN→NAT |
| **vendor** | — | — | [PL] | self | — |
| **GKE** | — | — | — | — | self |

- **Peer** = VPC Peering (direto, /16 vence a rota /8 do TGW)
- **TGW** = Transit Gateway (hub-and-spoke)
- **[PL]** = PrivateLink (apenas nível de serviço, porta 80)
- **TGW→VPN→NAT** = Cross-cloud via HA VPN com tradução de CIDRs
- **—** = Sem conectividade

## Ordem de Destroy

**Sempre destrua na ordem inversa das camadas** para evitar recursos órfãos:

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

> **Nota:** Internal Load Balancers do GKE criam forwarding rules no GCP que podem levar até 60 segundos para deletar. Se o destroy de `gcp/infra` falhar na VPC, aguarde e tente novamente.

## Estimativa de Custos

| Componente | Qtd | Custo/hr | Mensal (~730 hrs) |
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
| **Total** | | **~$1.05/hr** | **~$773/mês** |

> **Economia de custos:** Defina `create_nat_gateways = false` na AWS e `create_vpn = false` em ambos os lados quando não estiver testando cross-cloud. Isso reduz o custo para ~$400/mês. **Destrua tudo quando não estiver em uso.**

## CI/CD — GitHub Actions

Três workflows gerenciam deploy e destroy. O chicken-and-egg da VPN significa que o deploy é dividido em workflows por nuvem (trigger manual entre eles), enquanto o destroy é unificado.

| Workflow | Trigger | Jobs |
|----------|---------|------|
| `tf-deploy-aws.yml` | `workflow_dispatch` | networking → compute |
| `tf-deploy-gcp.yml` | `workflow_dispatch` | infra → apps |
| `tf-destroy.yml` | `workflow_dispatch` | gcp/apps → aws/compute → gcp/infra → aws/networking |

### Secrets Necessários

| Secret | Finalidade |
|--------|---------|
| `AWS_ACCESS_KEY_ID` | Credenciais AWS |
| `AWS_SECRET_ACCESS_KEY` | Credenciais AWS |
| `TF_API_TOKEN` | Terraform Cloud (setup-terraform action) |
| `TF_STATE_BUCKET` | Bucket S3 para remote state da AWS |
| `GCP_CREDENTIALS` | JSON key da Service Account GCP |

### Deploy via CI/CD

Devido ao chicken-and-egg da VPN, o deploy completo requer intervenção manual:

1. Execute o workflow **Deploy GCP** (cria GKE + HA VPN gateway)
2. Copie os IPs da VPN do GCP → defina como input do workflow ou `.tfvars`
3. Execute o workflow **Deploy AWS** (cria VPCs + conexões VPN)
4. Copie os detalhes dos tunnels da AWS → atualize o `.tfvars` do GCP
5. Re-execute o workflow **Deploy GCP** (completa os VPN tunnels + NAT VM + apps)

Para a configuração inicial da VPN, `terraform apply` local com passagem manual de variáveis (conforme descrito nas instruções de deploy acima) é mais prático. CI/CD é mais adequado para atualizações subsequentes após a VPN estar estabelecida.

### Destroy via CI/CD

Execute o workflow **Terraform Destroy** — ele destrói todas as 4 camadas em ordem inversa automaticamente, incluindo a espera pela limpeza do load balancer do GKE.

## Decisões de Design Principais

| Decisão | Justificativa |
|----------|-----------|
| **GCP cede (não a AWS)** | GCP Private NAT é cloud-native; a AWS não tem NAT gerenciado para VPN |
| **MASQUERADE (não NETMAP SNAT)** | IPs de origem sobrepostos são ambíguos — MASQUERADE usa um IP não-ambíguo |
| **NAT VM (não GCP Private NAT)** | Private NAT só lida com SNAT (saída); DNAT requer uma VM |
| **BGP (não rotas estáticas)** | Troca dinâmica de rotas; TGW auto-propaga rotas do GCP para todas as VPCs |
| **4 tunnels (não 2)** | HA completo: 2 conexões AWS × 2 tunnels cada, em 2 interfaces do GCP |
| **Monorepo (não repos separados)** | Mantém ambos os lados versionados juntos; ordem de deploy é documentada |
| **Custom adverts no Cloud Router** | `advertise_mode = CUSTOM` por peer para evitar conflito com Cloud NAT |

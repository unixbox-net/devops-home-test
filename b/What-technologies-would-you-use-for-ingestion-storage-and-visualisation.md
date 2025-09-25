# Technology Stack

## Technologies List

- **AWS Organizations / OUs / SCPs** — Multi-account governance with guardrails at scale; isolates blast radius and enforces policy centrally.
- **AWS Account Vending + IAM Identity Center (SSO)** — Automated account creation and SSO access; speeds onboarding while standardizing permissions.
- **AWS CloudTrail (org-level) → S3 with Object Lock (WORM)** — Tamper-evident audit trail for all API activity; meets compliance and forensics needs.
- **AWS Config + Conformance Packs (CIS/AWS Foundational)** — Continuous config drift detection against baselines; proves and enforces posture.
- **AWS Security Hub (CIS/FSBP) + GuardDuty + Access Analyzer** — Centralized finding aggregation, threat detection, and public-access checks; reduces risk.
- **AWS Budgets + Cost Anomaly Detection + Cost Explorer** — Cost guardrails and anomaly alerts; keeps ingestion/query/storage spend predictable.
- **Tag Policies & mandatory resource tags** — Enforced metadata for chargeback and access controls; enables cost allocation and automation.
- **Amazon VPC (multi-AZ)** — Isolated, resilient network fabric; forms the secure perimeter for all observability services.
- **Subnets (public/private/isolated) + Route Tables** — Layered network zones and routing; limits exposure and separates data paths.
- **Internet Gateway (IGW) & NAT Gateways (per-AZ)** — Controlled egress without public exposure; maintains HA and patchability.
- **Security Groups & NACLs** — Stateful and stateless filtering; tight east-west and north-south access for metrics/logs planes.
- **VPC Endpoints (Interface/Gateway) incl. PrivateLink for AMP/AMG/OpenSearch/Kinesis/S3/SSM/ECR/STS/CloudWatch** — Private, non-internet access to AWS services; lowers risk and latency.
- **Route 53 (Private Hosted Zone) + Resolver DNS Firewall** — Internal service discovery and DNS egress filtering; makes endpoints simple and safe.
- **AWS WAF + AWS Shield Advanced (public UIs)** — L7 filtering and DDoS protections for Grafana or portals; keeps UIs resilient.
- **AWS KMS (per-env CMKs, optional per-tenant BYOK)** — Key management and envelope encryption; isolates data cryptographically.
- **AWS IAM (least-privilege roles, permission boundaries)** — Fine-grained access control; prevents over-privileged data access paths.
- **AWS Systems Manager: Session Manager, Parameter Store, Automation** — SSH-less access, config storage, and runbooks; safer ops with strong audit.
- **EC2 Auto Scaling Groups (gateways, bastions, probes)** — Elastic, immutable fleets for collectors and health probes; scale with load.
- **Amazon EKS (optional: Mimir/Tempo/probers)** — Managed Kubernetes for self-hosted TSDB/tracing and jobs; provides knob-rich escape hatch.
- **Amazon ECR (images)** — Private registry for agent/gateway/container images; integrates with IAM/KMS and EKS.
- **Packer (golden AMIs) + cloud-init + systemd** — Immutable, fast-boot hosts with deterministic startup; enables cattle-style rollouts.
- **cosign/sigstore (image signing & attestations)** — Supply-chain integrity for AMIs/OCI; only trusted images run.
- **SBOM tooling (Syft/Grype)** — Software bill of materials and vuln scan; visibility and compliance for baked artifacts.
- **IMDSv2-only + SSH disabled (SSM only)** — Strong instance identity and no open SSH; reduces lateral movement and key sprawl.
- **WireGuard (overlay) on edge/gateway hosts** — Lightweight encrypted mesh for agents→gateways; simple keys and high performance.
- **Prometheus Node Exporter (host metrics)** — Standard host telemetry; baseline signals for capacity/SLOs across fleets.
- **Custom Gameplay Exporter (game SLIs)** — Player-centric counters/histograms (tick, action→ack); what matters to incidents.
- **AWS Distro for OpenTelemetry — ADOT (agent mode)** — On-host collector for batching/retry/TLS; efficient remote_write to gateways.
- **Fluent Bit (logs)** — Low-overhead log forwarder to Firehose/OpenSearch/S3; edge tokenization/redaction.
- **AWS Distro for OpenTelemetry — ADOT (gateway mode) / Prometheus remote_write gateway** — Central throttle/relabel/quotas; isolates AMP from bursty edges.
- **Envoy or Nginx (TLS, auth, 429/Retry-After)** — Front door for gateways; enforces mTLS, rate limits, and graceful backpressure.
- **Elastic Load Balancing (ALB/NLB as needed)** — HA entry points for UIs (ALB) and TCP collectors (NLB); simplifies failover.
- **Amazon Kinesis Data Streams (buffer/decoupler)** — Durable, scalable queue for metrics/logs; absorbs spikes and enables replay/fan-out.
- **Amazon Kinesis Firehose (logs→OpenSearch & S3)** — Managed delivery with batching/compression; cheap, reliable log pipelines.
- **Amazon Managed Service for Prometheus (AMP) (metrics hot store)** — Managed PromQL TSDB; offloads scaling/ops for 10s hot retention.
- **Grafana Mimir on EKS (optional alternative to AMP; S3-backed)** — Self-managed PromQL at massive scale with tighter multi-tenancy controls.
- **Amazon OpenSearch Service (logs hot + UltraWarm/Cold)** — Searchable logs with ILM tiers; quick investigations plus low-cost retention.
- **Amazon S3 (warm/cold metrics & logs; Parquet/ORC archives)** — Durable, cheap object store; powers long-range analytics and backups.
- **AWS Glue (catalog) + Glue ETL / AWS Lambda (downsampling jobs)** — Schema/catalog and ETL to Parquet; enables Athena-friendly rollups.
- **Amazon Athena (SQL on S3, long-range analytics)** — Serverless queries over S3 archives; ad-hoc analysis without clusters.
- **Amazon Managed Grafana (AMG) (dashboards & alerts)** — Central visualization with SSO/RBAC; unified views across AMP/OS/Athena.
- **Amazon CloudWatch Alarms (SLO, freshness, cache, object-store ops)** — Native alerting on platform health KPIs; ties autoscale to outcomes.
- **PagerDuty / Slack / AWS Chatbot (incident routing)** — Fast human loop closure; pages the right team with context.
- **AWS Fault Injection Simulator (FIS) (chaos testing)** — Safe, controlled failures (AZ/broker/ingester); proves resilience gates.
- **Terraform (IaC) / AWS CDK (optional)** — Repeatable provisioning and drift detection; infra as reviewed code.
- **GitHub Actions / AWS CodeBuild / CodePipeline (CI/CD)** — Build/test/deploy automation for AMIs, agents, and Terraform; shortens MTTR.
- **Argo CD (if EKS; GitOps)** — Declarative sync and rollbacks for cluster workloads; versioned operations.
- **AWS Backup (EC2/EBS, RDS if used) + OpenSearch snapshots to S3** — Policy-based backups and point-in-time recovery; protects state.
- **S3 Lifecycle & Replication (CRR if allowed)** — Tiering to IA/Glacier and cross-Region copies; cost control and DR.
- **Amazon Service Quotas (tracking & alarms)** — Monitors capacity limits (e.g., Kinesis shards); avoids hidden scaling caps.
- **Amazon Macie (sensitive data detection on S3 archives)** — ML-backed PII discovery; validates that archives remain compliant.


(grouped)

Org, Governance & Cost

AWS Organizations / OUs / SCPs – Central guardrails (deny public buckets/AMIs, enforce KMS/IMDSv2/regions); baseline compliance.

IAM Identity Center (SSO) – Federated access with least-privilege assignments.

CloudTrail (org-level) → S3 Object Lock – Tamper-evident audit logs for investigations and compliance.

AWS Config + Conformance Packs – Continuous compliance & auto-remediations (CIS/Foundational best practices).

Security Hub + GuardDuty + Access Analyzer – Consolidated security posture, threat findings, and unintended access detection.

Budgets + Cost Anomaly Detection + Cost Explorer – Cost visibility and auto-alerts on drift.

Tag Policies – Enforce Owner/CostCenter/Environment/Tenant/DataClass/Retention/PII tagging for chargeback and policy.

Networking & Perimeter

VPC (multi-AZ), Subnets, IGW/NAT – Resilient north-south & egress with private app subnets.

Security Groups & NACLs – Layered east-west and north-south isolation per role.

VPC Endpoints + PrivateLink – Private access to S3/AMP/AMG/OpenSearch/Kinesis/SSM/ECR/CloudWatch with endpoint policies.

Route 53 (PHZ) + DNS Firewall – Service discovery (obs.internal) and domain egress control.

WAF + Shield Advanced – DDoS & L7 filtering for any public UIs (Grafana, portals).

KMS (per-env CMKs / BYOK) – Strong encryption at rest; scoped key policies and rotation.

Compute, Images & Host Hardening

EC2 Auto Scaling Groups – Scale gateways/collectors/bastions/probes on SLOs, not CPU alone.

EKS (optional) – Run Mimir/Tempo/probers/Gateway if you need K8s knobs or multi-tenancy features.

ECR – Private registry for EKS/EC2 containers.

Packer + cloud-init + systemd – Immutable AMIs with deterministic boot and first-boot templating.

cosign/sigstore + SBOM (Syft/Grype) – Signed/provenanced images with supply-chain visibility and policy enforcement.

SSM (Session Manager/Automation/Parameter Store) – SSH-less access, safe runbooks, and configuration distribution.

IMDSv2-only, SSH disabled – Reduce lateral movement; all access via SSM.

Edge Agents & Gateways

WireGuard – Lightweight, scoped overlay for edge→gateway encryption and tenant mesh.

Node Exporter + Gameplay Exporter – Host + player-centric metrics (counters/histograms only).

ADOT (agent) – Batch, retry, TLS/mTLS; remote_write to gateway/AMP.

Fluent Bit – Low-overhead log shipping to Firehose/OpenSearch/S3.

ADOT (gateway) / Prometheus remote_write gateway – Central relabeling, per-tenant quotas, compression, and backpressure.

Envoy/Nginx + ALB/NLB – TLS termination, auth, and 429 + Retry-After when tenants exceed quotas.

Transport, Storage & Query

Kinesis Data Streams – Durable buffer to absorb bursts and support replay/fan-out (metrics/logs).

Kinesis Firehose – Managed logs fan-out to OpenSearch (hot) and S3 (archive).

Amazon Managed Prometheus (AMP) – Managed PromQL TSDB for hot metrics (10s); zero cluster ops.

Grafana Mimir on EKS (optional) – S3-backed PromQL alternative with fine tenancy/limits control.

Amazon OpenSearch Service – Log search (3–7d hot) with ILM; UltraWarm/Cold for cost.

Amazon S3 – Warm/cold metrics (Parquet/ORC) and raw logs; lifecycle to IA/Glacier and optional CRR.

Glue + Lambda (ETL/downsampling) – Build long-range rollups and partitioned Parquet.

Athena – SQL on S3 for historical analytics and Grafana datasource.

Visualization, SLOs & Incident Flow

Amazon Managed Grafana (AMG) – Dashboards for AMP/OpenSearch/Athena; SSO/RBAC; alerting rules.

CloudWatch Alarms – SLO alarms: freshness p99, ingest TTFB p99, query p95/p99, cache hit, object-store ops/query.

PagerDuty / Slack / AWS Chatbot – On-call routing and ChatOps.

Security, Secrets & Backups

Secrets Manager / Parameter Store – Credentials & WireGuard keys; rotation ≤90d; no secrets in images.

AWS Backup (EC2/EBS, RDS if used) – Policy-driven backups; cross-region copies if allowed.

OpenSearch snapshots → S3 – Daily/HOURLY snapshots for restore.

S3 Lifecycle & Replication – Hot→IA @30d; IA→Glacier @180d; expire per policy; optional CRR for DR.

Macie – Sensitive-data detection in S3 archives.

CI/CD & Testing

Terraform / CDK – Declarative provisioning for all resources and guardrails.

GitHub Actions / CodeBuild / CodePipeline – AMI builds, Terraform plan/apply, config sync.

Argo CD (if EKS) – GitOps for cluster workloads.

AWS Fault Injection Simulator (FIS) – AZ/broker/ingester chaos to validate DR and SLOs.

Operations, Quotas & DR

Service Quotas (monitored) – Kinesis shards, AMP series, OpenSearch storage, AMG seats—alarms & auto-requests.

S3 CRR (if allowed) – DR copy for archives; runbook to re-point Athena/AMG.

Runbooks & GameDays – Quarterly restores (OS index, S3 prefix, Terraform state, AMIs) to prove RPO/RTO.


### Technology List (with Why/Purpose)

## Networking & Foundations (per region)
-  Amazon VPC — Private network boundaries (public/private/isolated subnets), multi-AZ resilience.
-  Internet Gateway / NAT Gateways (1 per AZ) — Egress for private subnets without exposing instances.
-  VPC Endpoints (Interface/Gateway) — Private access to S3, AMP, AMG, Kinesis, Firehose, OpenSearch, SSM, ECR, STS, CloudWatch (no public internet).
-  AWS Route 53 (private hosted zone) — Service discovery (e.g., obs.internal) for gateways and backends.
-  AWS WAF (on public UIs, if any) — Edge filtering for Grafana or custom portals.
-  AWS KMS — Key management for at-rest encryption (metrics, logs, S3, Secrets).
-  AWS IAM — Least-privilege roles and scoped data-source access.
-  AWS Certificate Manager (ACM) — TLS cert lifecycle for frontends and ALBs.
-  AWS Systems Manager (SSM) — Session Manager (SSH-less access), Parameter Store, fleet ops.

## Compute & Golden Images
-  EC2 Auto Scaling Groups (ASG) — Horizontal scale for collector/gateway and admin/bastion nodes.
-  Packer — Builds golden AMIs (immutable base for edge, gateway, bastion).
-  cloud-init & systemd — First-boot templating and deterministic service start order.
-  cosign / sigstore (image signing) — Provenance + enforcement (only signed AMIs/OCI run).
-  SBOM tools (e.g., Syft/Grype) — Supply-chain visibility for baked images and agents.

## Agents (on game/edge hosts)
-  Prometheus Node Exporter — Host metrics (CPU, mem, disk, net).
-  Custom Gameplay Exporter — Player-centric counters & histograms (tick time, action→ack).
-  AWS Distro for OpenTelemetry (ADOT) — Agent mode — Batching, retry, remote_write to gateway; TLS/mTLS.
-  Fluent Bit — Lightweight log shipping to Kinesis Firehose / OpenSearch / S3.
-  WireGuard — Secure overlay for edge→gateway paths; supports multi-tenant meshes.

## Collector / Gateway Layer (EC2)
-  ADOT — Gateway mode (or Prometheus Remote-Write Gateway) — Central throttling, relabeling, per-tenant quotas, mTLS termination.
-  Envoy / Nginx (front of gateway) — TLS, 429 + Retry-After on overage, request shaping and auth.
-  Security Groups & NACLs — Tight east-west and north-south rule sets; per-role isolation.

## Transport, Storage & Query
-  Amazon Kinesis Data Streams — Optional buffer & decoupler for metrics/logs; absorbs spikes, enables replay.
-  Amazon Kinesis Firehose — Managed fan-out logs→OpenSearch (hot) and logs→S3 (archive).
-  Amazon Managed Service for Prometheus (AMP) — Managed PromQL TSDB for metrics (hot 10s); no cluster to run.
-  Amazon OpenSearch Service — Logs hot search (3–7 days) with index lifecycle; UltraWarm optional.
-   mazon S3 — Warm/cold stores: metrics downsampled (Parquet/ORC), logs raw/archives; lifecycle to IA/Glacier.
-  AWS Glue / AWS Lambda (ETL jobs) — Downsample metrics to Parquet, build long-range rollups.
-  Amazon Athena — SQL on S3 for historical analytics; Grafana can query it too.

## Visualization, Alerting & Incident Flow
-  Amazon Managed Grafana (AMG) — Dashboards for AMP/OpenSearch/Athena; SSO/RBAC; alert rules.
-  Amazon CloudWatch Alarms — SLO alarms: freshness, write TTFB, query p95/p99, object-store ops/query, cache hit.
-  PagerDuty / Slack (integrations) — On-call routing and incident comms.

## Optional (Traces, K8s, Escape Hatches)
-  AWS X-Ray (managed) or Grafana Tempo (EKS) — Distributed tracing.
-  Amazon EKS (optional) — Host Tempo, synthetic prober jobs, or future self-managed metrics stack.
-  Amazon ECR — Private container registry for any EKS/EC2 workloads.
-  Amazon MSK (Kafka) (alternative to Kinesis) — If you need Kafka semantics/connectors.
-  Grafana Mimir on EKS (alternative to AMP) — Object-store backed PromQL with finer multi-tenancy knobs.

## Security, Identity & Governance
-  mTLS (SPIFFE/SPIRE optional) — Strong identity for agents/gateways; short-lived certs.
-  Secrets Manager & Parameter Store — WireGuard keys, AMP tokens, OpenSearch creds; no secrets in images.
-  AWS CloudTrail + S3 Object-Lock (WORM) — Audit logs are tamper-evident and immutable.
-  AWS Config / Security Hub — Conformance checks and continuous controls monitoring.
-  IMDSv2-only, SSH-disabled (SSM only) — Reduce lateral movement and harden hosts.

## CI/CD & IaC
-  Terraform (or AWS CDK) — Declarative provisioning: VPC, endpoints, KMS, S3, Kinesis/Firehose, OpenSearch, AMP/AMG, ASGs.
-  GitHub Actions / AWS CodeBuild — Pipelines for Packer AMIs, Terraform plans/applies, config pushes.
-  Argo CD (if EKS) — GitOps for any cluster-resident services (Tempo, gateways, probes).

## Data Modeling & Policy
-  Prometheus Histograms (incl. OTel exponential) — Accurate p95/p99 with bounded series.
-  Recording Rules — Precompute rollups, reduce query cost, improve dashboard p95.
-  Label Allowlist + CI Lints — Strict schema: {region, az, cluster, shard_id, instance_type, build_id, queue, asn_bucket}; reject PII and high-cardinality labels at edge.
-  Per-Tenant Quotas & Limits — Samples/s, max series, query limits enforced at gateway → AMP/OpenSearch.

## SLO Telemetry (platform health)
-  Freshness metric (write→read age) — Objective “are graphs current?” indicator on all boards.
-  Ingest TTFB timers (gateway) — Detect TLS/queueing issues early.
-  Query Latency (AMG/AMP OS metrics) — p95/p99 targets; autoscale tied to user-visible outcomes.
-  Cost Telemetry — S3 bytes/day added, OpenSearch hot shard pressure, object-store ops per query, cache hit.

## Testing, Load & Chaos (Acceptance Gates T0–T8)
-  Synthetic Producers (metrics) — Generate counters & exponential histograms with real label shapes (1×/3×/5×).
-  Dashboard Replay Loaders — Simulate 200 viewers and mix of query ranges (≤12h / 7–30d).
-  Chaos Scripts — Cordon/drain AZ node pools, stop gateway, shard pauses to prove replay and backpressure.
-  Probes (EC2 tiny or Lambda) — Outside-in checks for freshness and ingest success.

## Cost & FinOps Levers
-  Downsampling to S3 (Glue/Lambda) — Cheap long-range queries via Athena.
-  Grafana Result Cache & Query Budgets — Keep p95 low during incidents; protect caches.
-  OpenSearch ILM + UltraWarm — Move logs off hot quickly without losing searchability.
-  S3 Lifecycle — Transition IA/Glacier and expirations that match policy.



### Improvements (Reference Add-Ons)

## Immutable Golden Images (deterministic rollouts)
Why: Eliminate config drift; boot fast; rollback by AMI ID.
Tech: Packer, SBOM (Syft/Grype), cosign, read-only FS, cloud-init last-mile, ASG instance refresh, /ready health-gate.

## Cilium + Hubble & eBPF Summaries (future/optional)
Why: Kernel-level truth (TCP retrans, run queue), L3–L7 flow visibility without app changes; XDP drop/shape junk early.
Tech: Cilium CNI + Hubble, BCC/bpftrace/Parca, custom kprobes/tracepoints, XDP filters; Prom metrics exporters and dashboards.

## Firecracker MicroVM Sidecars (agent isolation)
Why: Strong isolation for noisy telemetry agents on hot hosts; predictable performance; fast restart.

Tech: firecracker-containerd, minimal rootfs image for ADOT/Fluent Bit/exporters, cgroup caps (0.5–1 vCPU), WireGuard inside guest.

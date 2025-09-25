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

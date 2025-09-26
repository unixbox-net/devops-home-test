# Explain Your Reasons, Thought Processes, and Assumptions (with References)

This document explains **why** the proposed Reporting & Observability Platform (AWS) looks the way it does, **how** the decisions were made, and **which sources and assumptions** were relied upon. It is designed to be auditable: every major claim links to a primary reference (AWS/Grafana/Prometheus docs, Google SRE book, standards, or vendor whitepapers).

---

## 1) Goals, SLOs, and Constraints (What success looks like)

- **Primary goal:** Player‑centric observability for a title peaking at **~1,000,000 CCU** with **low‑latency reporting**, enabling rapid incident triage and data‑driven rollout safety.
- **Service Level Objectives (platform):**
  - **Freshness (write→read)**: p99 ≤ **10 s** for hot metrics windows. Ref: AMP/Mimir best practices on ingestion & query windows ([AMP Docs](https://docs.aws.amazon.com/prometheus/latest/userguide/what-is-AWS-Managed-Prometheus.html), [Mimir Architecture](https://grafana.com/docs/mimir/latest/references/architecture/)).
  - **Query latency**: p95 ≤ **2 s** (≤12 h windows); p99 ≤ **10 s** (7–30 d windows). Ref: Grafana query performance guidance ([Grafana Docs](https://grafana.com/docs/grafana/latest/best-practices/)) and Mimir query-frontend ([Mimir Query Frontend](https://grafana.com/docs/mimir/latest/references/architecture/components/query-frontend/)).
  - **Ingest TTFB**: p99 ≤ **250–350 ms** at 1×–3× load (detect TLS/queueing issues early). Ref: Gregg, _Systems Performance, 2e_ (socket first byte, latency sources) ([book site](https://www.brendangregg.com/systems-performance-2nd-edition-book.html)).
- **Security constraints:** Zero PII in metrics, mTLS in transit, KMS at rest, IAM least privilege. Refs: [AWS Well‑Architected Security Pillar](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html), [KMS](https://docs.aws.amazon.com/kms/latest/developerguide/overview.html), [ACM](https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html).  
- **Ops constraints:** Immutable artifacts (golden AMIs/OCI), GitOps/IaC, auditability. Refs: [Packer](https://developer.hashicorp.com/packer), [Terraform](https://developer.hashicorp.com/terraform), [Argo CD](https://argo-cd.readthedocs.io/en/stable/).

---

## 2) Core Assumptions & Sizing Model (What we assume and why)

- **Population**: ~**1,000,000 CCU**, roughly NA/EU/APAC split ⇒ drives shards, quotas, and AZ spread. Ref: SRE “Monitoring Distributed Systems” ([SRE Book](https://sre.google/sre-book/monitoring-distributed-systems/)).  
- **Game host density**: ~**200 CCU/server** ⇒ **~5,000 servers** total (~1,700/region). Ref: Gregg’s **USE method** (size by Utilization/Saturation/Errors) ([USE Method](https://www.brendangregg.com/usemethod.html)).  
- **Emission cadence**: **10 s** steady; **5 s** during incidents to increase resolution without overwhelming ingest. Ref: SRE tradeoffs between signal fidelity vs overhead ([SRE Book](https://sre.google/sre-book/monitoring-distributed-systems/)).
- **Metric shapes**: **counters + histograms (incl. OTel exponential)** only; no per‑event time series; strictly bounded labels; **~300 active series per server**. Refs: Prometheus histograms ([Prom Histograms](https://prometheus.io/docs/practices/histograms/)), OTel exponential histograms ([OTel Metrics: Exponential Histograms](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exponential-histogram)).

### Derived capacity
- **EPS math**: 5,000 servers × 300 series ÷ 10 s ≈ **150k samples/s** (global) ≈ **50k/s per region**. Plan ≥30% headroom ⇒ target **≥200k/s global**.  
- **Storage**: ~15–20 B/sample ⇒ ~**200–260 GB/day** (global hot). Budget **~500 GB/day/region** to cover index/replicas/overhead. Refs: Prometheus storage model ([Prom Storage](https://prometheus.io/docs/prometheus/latest/storage/)), Mimir object‑store architecture ([Mimir Store‑Gateway](https://grafana.com/docs/mimir/latest/references/architecture/components/store-gateway/)).

---

## 3) Design Method (How choices were made)

1. **Start from user outcomes** (player‑felt SLIs): tick health, action→ack, join errors (RED method) ([Grafana RED](https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/)).  
2. **Bound cardinality at the edge**: schema allowlist; CI linting; runtime reject of PII/high‑cardinality labels ([Prom Naming/Cardinality](https://prometheus.io/docs/practices/naming/)).  
3. **Decouple via streams**: **Kinesis** (or **MSK**) buffers bursts, enables replay, and multi‑sink fan‑out ([Kinesis Data Streams](https://docs.aws.amazon.com/streams/latest/dev/introduction.html), [Amazon MSK](https://docs.aws.amazon.com/msk/latest/developerguide/what-is-msk.html)).  
4. **Object‑store‑backed TSDB**: **AMP** (managed) or **Mimir on EKS**, with recording rules, query‑frontend, and caches ([AMP](https://docs.aws.amazon.com/prometheus/latest/userguide/what-is-AWS-Managed-Prometheus.html), [Mimir Architecture](https://grafana.com/docs/mimir/latest/references/architecture/)).  
5. **Tiered retention**: hot 10s; warm downsampled 1–5m; cold Parquet/ORC on S3 with Athena ([S3 Lifecycle](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html), [Athena](https://docs.aws.amazon.com/athena/latest/ug/what-is.html)).  
6. **SLO‑driven autoscale & guardrails**: scale on freshness/query p95/cache hit, not CPU; reject overload before meltdown ([SRE Handling Overload](https://sre.google/sre-book/handling-overload/)).

---

## 4) Why These Technologies (and the alternatives)

### Agents & Edge
- **Node Exporter** (host) + **custom gameplay exporter** (SLIs): standard Prom model; portable; low overhead ([Node Exporter](https://github.com/prometheus/node_exporter)).  
- **ADOT Collector** (agent): batching, retry, TLS, Prom remote_write; managed distro alignment ([ADOT](https://aws-otel.github.io/docs/getting-started/collector)).  
- **Fluent Bit** (logs): lightweight, back‑pressure aware; ships to Firehose/S3/OpenSearch ([Fluent Bit](https://docs.fluentbit.io/)).  
- **WireGuard** (overlay): fast, simple crypto mesh; isolates tenant traffic ([WireGuard](https://www.wireguard.com/)).

**Why not ship raw events?** Per‑event metrics explode cardinality & cost; histograms preserve p95/p99 with bounded series ([Prom Histograms](https://prometheus.io/docs/practices/histograms/)).

### Transport & Buffering
- **Kinesis Data Streams** (or **MSK**) buffers, smooths bursts, and enables replay/outage isolation ([Kinesis](https://docs.aws.amazon.com/streams/latest/dev/introduction.html)).  
- **Kinesis Firehose** routes logs to OpenSearch (hot) and S3 (archive) without managing consumers ([Firehose](https://docs.aws.amazon.com/firehose/latest/dev/what-is-this-service.html)).

### Metrics Store (two paths)
- **Amazon Managed Service for Prometheus (AMP)**: managed PromQL TSDB; no cluster ops; integrates with AMG & IAM ([AMP](https://docs.aws.amazon.com/prometheus/latest/userguide/what-is-AWS-Managed-Prometheus.html)).  
- **Grafana Mimir on EKS + S3**: stronger multi‑tenancy knobs and cost control; more to operate ([Mimir](https://grafana.com/docs/mimir/latest/)).

### Logs & Traces
- **Amazon OpenSearch Service** (hot 3–7 d + UltraWarm/Cold): query hot logs quickly; ILM for cost ([OpenSearch](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/what-is.html)).  
- **S3 + Glue + Athena**: long‑term log/metrics archives; cheap analytics ([S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html), [Glue](https://docs.aws.amazon.com/glue/latest/dg/what-is-glue.html), [Athena](https://docs.aws.amazon.com/athena/latest/ug/what-is.html)).  
- **AWS X‑Ray** or **Grafana Tempo** (optional) for traces ([X‑Ray](https://docs.aws.amazon.com/xray/latest/devguide/aws-xray.html), [Tempo](https://grafana.com/oss/tempo/)).

### Visualization & Alerting
- **Amazon Managed Grafana (AMG)**: dashboards, SSO/RBAC, alert rules; supports AMP/OpenSearch/Athena ([AMG](https://docs.aws.amazon.com/grafana/latest/userguide/what-is-Amazon-Managed-Grafana.html)).  
- **CloudWatch Alarms**: platform SLO/burn rate/freshness; integrates with **PagerDuty/Slack/AWS Chatbot** ([CloudWatch Alarms](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/AlarmThatSendsEmail.html), [AWS Chatbot](https://docs.aws.amazon.com/chatbot/latest/adminguide/what-is.html)).

### Security, Identity, and Governance
- **IAM least privilege**, **KMS per env**, **mTLS** (SPIFFE/SPIRE optional), **SSM Session Manager**, **ACM certs**, **CloudTrail to S3 Object‑Lock** (WORM) ([IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction.html), [SPIFFE/SPIRE](https://spiffe.io/), [SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html), [CloudTrail + Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)).  
- **Config, Security Hub, GuardDuty, Access Analyzer** for continuous posture ([Config](https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html), [Security Hub](https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub.html), [GuardDuty](https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html)).

### Golden Images & Supply Chain
- **Packer** (golden AMIs) + **cloud-init** + **systemd**: immutable, fast boots; deterministic rollouts ([Packer](https://developer.hashicorp.com/packer)).  
- **cosign/sigstore** for signing/attestations; **Syft/Grype** for SBOM & vuln scan ([cosign](https://docs.sigstore.dev/cosign/overview/), [Syft/Grype](https://github.com/anchore/syft)).  
- **IMDSv2‑only**, **SSH disabled** (SSM only) ([IMDSv2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)).

### Optional Enhancements
- **Cilium + Hubble** for L3–L7 flow visibility on EKS; **eBPF/XDP** summaries for kernel‑level truth ([Cilium](https://docs.cilium.io/en/stable/), [Hubble](https://docs.cilium.io/en/stable/overview/intro/#hubble)).  
- **Firecracker** microVM sidecar for agent isolation on hot hosts ([Firecracker](https://github.com/firecracker-microvm/firecracker)).

---

## 5) Retention & Cost Strategy (Why tiering and how)

- **Metrics**: hot 10s for **7–14 d** (AMP/Mimir); warm **1–5 m** rollups for **90–180 d**; cold **Parquet/ORC on S3** for ~13 months. Refs: Prometheus recording rules ([Recording Rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/)), Mimir compactor/bucket‑index ([Mimir Compactor](https://grafana.com/docs/mimir/latest/references/architecture/components/compactor/)).  
- **Logs**: **OpenSearch hot** 3–7 d → **UltraWarm/Cold** → **S3** archive via Firehose/ILM ([OpenSearch UltraWarm/Cold](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/ultrawarm.html)).  
- **Lifecycle**: S3 transitions to IA/Glacier + expirations ([S3 Lifecycle](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)).  
- **Cost controls**: result caching, query budgeting, downsampling pipelines (Glue/Lambda), ILM policies. Refs: Mimir query sharding/caching ([Mimir Query Frontend](https://grafana.com/docs/mimir/latest/references/architecture/components/query-frontend/)).

---

## 6) Capacity Validation & “Prove‑It” Gates (How we know it scales)

- **Synthetic ingest soak**: ≥ **200k samples/s global** for 2–6 h; zero loss; write→read p95 < 30 s.  
- **Burst drills**: 1×/3×/5× spikes (patch/match); backlog drains < 30 min; gameplay SLIs intact.  
- **Query load**: ~200 concurrent viewers; p95 ≤ 2 s (≤12 h); p99 ≤ 10 s (7–30 d); cache hit ≥ 80%.  
- **Chaos**: Kill one AZ’s ingesters/queriers or a broker; no data loss; freshness recovers < 2 min.  
- **Replay**: Pause stream partitions 10–20 m; clean catch‑up; no out‑of‑order blowups.  
- **Autoscaling** on **freshness/query p95/cache hit** (not CPU).  
Refs: SRE on overload management ([SRE Book](https://sre.google/sre-book/handling-overload/)), Kafka/Kinesis tuning ([MSK Perf](https://docs.aws.amazon.com/msk/latest/developerguide/optimizing-your-amazon-msk-cluster.html)).

---

## 7) Security & Compliance Reasoning (Why these controls)

- **PII‑free metrics** by schema; **edge tokenization** for logs; **mTLS everywhere**; **KMS at rest**; **least privilege IAM**. Refs: [AWS Well‑Architected](https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html), [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks/).  
- **Auditability**: CloudTrail → **S3 Object‑Lock (WORM)**; Config + Security Hub posture; quarterly access reviews. Refs: [CloudTrail](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html), [Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html).  
- **Golden images** + signatures + SBOMs ⇒ provenance and drift‑free fleet. Refs: [cosign](https://docs.sigstore.dev/cosign/overview/), [Syft/Grype](https://github.com/anchore/syft).

---

## 8) Trade‑offs Considered (What we didn’t choose and why)

- **Managed (AMP/AMG/OpenSearch) vs self‑managed (Mimir/Tempo/Elastic)**: Start managed to reduce undifferentiated ops; switch to self‑managed only when multi‑tenancy knobs or cost controls demand it.  
- **Kinesis vs MSK**: Kinesis for turnkey scaling/replay; MSK if Kafka ecosystem/connectors are strategic.  
- **Per‑event metrics vs histograms**: rejected per‑event due to cardinality and cost; histograms preserve tail accuracy.  
- **Per‑tenant KMS keys (BYOK)**: optional; adopt for regulated studios/projects that require cryptographic segregation.

---

## 9) References (Primary Sources)

- **Google SRE Book**: Monitoring, handling overload, SLOs  
  - https://sre.google/sre-book/monitoring-distributed-systems/  
  - https://sre.google/sre-book/handling-overload/
- **Prometheus**: Histograms, naming/cardinality, recording rules, storage model  
  - https://prometheus.io/docs/practices/histograms/  
  - https://prometheus.io/docs/practices/naming/  
  - https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/  
  - https://prometheus.io/docs/prometheus/latest/storage/
- **OpenTelemetry**: Exponential histograms  
  - https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exponential-histogram
- **Grafana Mimir**: Architecture, store‑gateway, compactor, query‑frontend  
  - https://grafana.com/docs/mimir/latest/references/architecture/  
  - https://grafana.com/docs/mimir/latest/references/architecture/components/store-gateway/  
  - https://grafana.com/docs/mimir/latest/references/architecture/components/compactor/  
  - https://grafana.com/docs/mimir/latest/references/architecture/components/query-frontend/
- **AWS Managed Prometheus (AMP)** & **Managed Grafana (AMG)**  
  - https://docs.aws.amazon.com/prometheus/latest/userguide/what-is-AWS-Managed-Prometheus.html  
  - https://docs.aws.amazon.com/grafana/latest/userguide/what-is-Amazon-Managed-Grafana.html
- **Kinesis / Firehose / MSK**  
  - https://docs.aws.amazon.com/streams/latest/dev/introduction.html  
  - https://docs.aws.amazon.com/firehose/latest/dev/what-is-this-service.html  
  - https://docs.aws.amazon.com/msk/latest/developerguide/what-is-msk.html
- **OpenSearch Service** (UltraWarm/Cold)  
  - https://docs.aws.amazon.com/opensearch-service/latest/developerguide/what-is.html  
  - https://docs.aws.amazon.com/opensearch-service/latest/developerguide/ultrawarm.html
- **S3 + Lifecycle + Athena + Glue**  
  - https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html  
  - https://docs.aws.amazon.com/athena/latest/ug/what-is.html  
  - https://docs.aws.amazon.com/glue/latest/dg/what-is-glue.html
- **Security & Compliance**: IAM, KMS, ACM, SSM, CloudTrail Object‑Lock, Config, Security Hub, GuardDuty  
  - https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction.html  
  - https://docs.aws.amazon.com/kms/latest/developerguide/overview.html  
  - https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html  
  - https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html  
  - https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html  
  - https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html  
  - https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub.html  
  - https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
- **Golden images & supply chain**: Packer, cosign/sigstore, Syft/Grype  
  - https://developer.hashicorp.com/packer  
  - https://docs.sigstore.dev/cosign/overview/  
  - https://github.com/anchore/syft
- **Optional**: Cilium/Hubble, Firecracker  
  - https://docs.cilium.io/en/stable/  
  - https://github.com/firecracker-microvm/firecracker
- **Brendan Gregg**: USE method; _Systems Performance_ 2e  
  - https://www.brendangregg.com/usemethod.html  
  - https://www.brendangregg.com/systems-performance-2nd-edition-book.html

---

## 10) Summary (Tie‑back)

The recommendation prioritizes **bounded cardinality, managed services where wise, object‑store economics, and SLO‑driven operations**. Each element is grounded in vendor documentation and SRE best practices, with explicit scaling gates (T0–T8) that convert assumptions into **measurable** acceptance criteria. The result: a platform that is **fast enough to see reality**, **robust enough to survive events**, and **simple enough to operate at 1M CCU**.

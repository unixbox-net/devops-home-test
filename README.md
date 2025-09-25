# Reporting & Observability Platform (AWS)

**Purpose:** Define scope, design, build, implementation, and operations for a metrics/logs/tracing platform capable of supporting ~**1,000,000** concurrent clients with low‑latency reporting.

---

## Table of Contents

- [Document Control](#document-control)
- [Executive Summary — 1M-CCU Metrics & Reporting Platform (AWS)](#executive-summary--1m-ccu-metrics--reporting-platform-aws)
  - [Assumptions that shape the design](#assumptions-that-shape-the-design)
  - [What data the cluster holds](#what-data-the-cluster-holds)
  - [How it stays performant (by construction)](#how-it-stays-performant-by-construction)
  - [Technologies (AWS-native, with escape hatches)](#technologies-aws-native-with-escape-hatches)
  - [Retention & cost posture (simple, defensible)](#retention--cost-posture-simple-defensible)
  - [SLOs that keep us honest](#slos-that-keep-us-honest)
  - [How we prove 1M CCU readiness (acceptance gates)](#how-we-prove-1m-ccu-readiness-acceptance-gates)
  - [Rationale & trade-offs](#rationale--trade-offs)
  - [Risks & mitigations](#risks--mitigations)
- [1. Scope & Non-Goals](#1-scope--non-goals)
  - [1.1 In Scope](#11-in-scope)
  - [1.2 Out of Scope (see Improvements)](#12-out-of-scope-see-improvements)
  - [1.3 Improvements Roadmap (90/180/365-day)](#13-improvements-roadmap-90180365-day)
- [2. Assumptions / Constraints & Design Methodology](#2-assumptions--constraints--design-methodology)
  - [2.1 Workload & Resource Analysis](#21-workload--resource-analysis)
  - [2.2 Signal Shapes](#22-signal-shapes)
  - [2.3 Ingestion & Transport](#23-ingestion--transport)
  - [2.4 Storage & Retention](#24-storage--retention)
  - [2.5 Query & Visualization](#25-query--visualization)
  - [2.6 SLOs & Freshness](#26-slos--freshness)
  - [2.7 Tenancy & Quotas](#27-tenancy--quotas)
  - [2.8 Security & Compliance (Essentials)](#28-security--compliance-essentials)
    - [2.8.1 Principles](#281-principles)
    - [2.8.2 Day-1 Controls (checklist)](#282-day-1-controls-checklist)
    - [2.8.3 Minimal framework alignment](#283-minimal-framework-alignment)
  - [2.9 Capacity Tests (Pass/Fail Gates)](#29-capacity-tests-passfail-gates)
- [8. Architecture (AWS)](#8-architecture-aws)
  - [8.1 Components & AWS Services](#81-components--aws-services)
  - [8.2 Data Flow (high level)](#82-data-flow-high-level)
- [9. Capacity & Storage Planning](#9-capacity--storage-planning)
  - [9.1 Ingest & Storage](#91-ingest--storage)
  - [9.2 Retention (fill with final choices)](#92-retention-fill-with-final-choices)
  - [9.3 S3 Lifecycle (concept)](#93-s3-lifecycle-concept)
- [10. SLOs, Alerts & Dashboards](#10-slos-alerts--dashboards)
  - [10.1 SLOs](#101-slos)
  - [10.2 Alert Policy (examples to instantiate)](#102-alert-policy-examples-to-instantiate)
  - [10.3 Dashboard Standards (add links/screens later)](#103-dashboard-standards-add-linksscreens-later)
- [11. Tenancy, Quotas & Fairness](#11-tenancy-quotas--fairness)
- [12. Security & Compliance (Essentials)](#12-security--compliance-essentials)
  - [12.1 Principles (recap)](#121-principles-recap)
  - [12.2 Day-1 Checklist](#122-day-1-checklist)
- [13. Build & Implementation Plan](#13-build--implementation-plan)
  - [13.1 Environments](#131-environments)
  - [13.2 Delivery Milestones (fill dates)](#132-delivery-milestones-fill-dates)
  - [13.3 RACI (example)](#133-raci-example)
- [14. Operations](#14-operations)
  - [14.1 Runbooks (link/add later)](#141-runbooks-linkadd-later)
  - [14.2 SRE On-call](#142-sre-on-call)
  - [14.3 Change Management](#143-change-management)
- [15. Capacity Tests & Readiness Gates](#15-capacity-tests--readiness-gates)
- [16. Cost & FinOps (initial)](#16-cost--finops-initial)
- [17. Risks & Mitigations](#17-risks--mitigations)
- [18. Open Questions](#18-open-questions)
- [19. Appendices (to attach later)](#19-appendices-to-attach-later)
- [20. Improvements Adornment (reference-only, out of scope for Day-1)](#20-improvements-adornment-reference-only-out-of-scope-for-day-1)
  - [20.1 Immutable Golden Images (deterministic rollouts)](#201-immutable-golden-images-deterministic-rollouts)
  - [20.2 Cilium + Hubble & eBPF summaries](#202-cilium--hubble--ebpf-summaries)
  - [20.3 Firecracker microVM sidecars (agent isolation)](#203-firecracker-microvm-sidecars-agent-isolation)

---

## Document Control
- **Owner:** Anthony Carpenter  
- **Version / Date:** v1.0 — 2025‑09‑24  
- **Stakeholders:** Customer X  
- **Reviewers / Approvers:** Daniel Fox / Tom  
- **Related Docs:** _(add links)_

---

## Executive Summary — 1M-CCU Metrics & Reporting Platform (AWS)

Design and operate a metrics cluster that ingests and visualizes gameplay and platform telemetry for a title peaking at **1,000,000 CCU**, split roughly NA/EU/APAC. The goal is **player‑centric observability**: dashboards that reflect reality fast enough to diagnose and fix incidents while keeping **cost and cardinality predictable** at scale.

### Assumptions that shape the design
- **Scale model:** ~1M CCU, ~even across 3 regions; ~**200 CCU/server ⇒ ~5,000 servers (~1,700/region)**.  
- **Emission cadence:** **10 s** steady; **5 s** during incidents.  
- **Signal shape:** edge‑aggregated **counters + (exponential) histograms** only; ~**300 active series/server**; strict label allowlist (e.g., `region, az, cluster, shard_id, instance_type, build_id, queue, asn_bucket`) with **PII forbidden**.  
- **Capacity math (metrics):** 5,000 × (300 ÷ 10 s) ≈ **150k samples/s global** (~50k/s/region). Plan ≥30% headroom ⇒ **≥200k/s global** target.  
- **Storage budget (order of magnitude):** ~**15–20 B/sample** ⇒ **~200–260 GB/day global (hot)**; budget **~500 GB/day/region (hot)** to cover index/replicas.

### What data the cluster holds
- **Gameplay SLIs:** tick time histograms, action→ack latency histograms, instance density, queue/admission counters, error rates, voice MOS.  
- **Infra & network SLIs:** host CPU/mem/GC, disk I/O latency, NIC utilization/retransmits, SYN backlog; **edge RTT/jitter/loss histograms** bucketed by ASN.  
- **Ops/business overlays:** CCU, rollout %, error‑budget burn, ingest QPS, cache hit. *(Player‑level details stay in logs; metrics remain PII‑free.)*

### How it stays performant (by construction)
1. **Don’t flood it.** Servers emit **summaries only** (counters + histograms). No per‑event time series.  
2. **Bound cardinality.** Strict label allowlist and **~300 series/server** budget enforced in CI and at the edge; rollouts gated on budget.  
3. **Decouple producers.** Telemetry first lands in a **stream (Kinesis/MSK)** to absorb bursts, enable replay, and fan‑out.  
4. **Tiered retention.** Hot **10s** for ~14 d, warm **1–5 m** for 180+ d, **cold Parquet/ORC on S3** for audits/backfills. Recording rules precompute p95/p99 and rollups.  
5. **SLO‑driven backpressure.** Quotas at edge→broker→ingesters→queriers; shed non‑critical classes first (e.g., verbose logs).  
6. **Security & tenancy.** Per‑team tenants/quotas; TLS/KMS; PII‑free metrics.

### Technologies (AWS-native, with escape hatches)
- **Agents:** Prometheus node exporter + custom gameplay exporter; **ADOT Collector** (batch/retry/TLS/remote_write); **Fluent Bit** (logs).  
- **Ingestion & archive:** **Kinesis Data Streams** (or **Amazon MSK**). **Firehose** → **OpenSearch** (hot logs) & **S3** (archives).  
- **Metrics store (per region):** **Amazon Managed Service for Prometheus (AMP)** *or* **Grafana Mimir on EKS** (S3‑backed, multi‑tenancy controls).  
- **Logs & traces:** **OpenSearch** (hot 3–7 d) + **S3/Glue/Athena** (warm/cold); **AWS X‑Ray** or **Grafana Tempo**.  
- **Visualization & alerting:** **Amazon Managed Grafana (AMG)**; **CloudWatch Alarms** for burn rates, write→read age, query p95 → PagerDuty/Slack.  
- **Platform/IaC:** **EKS, ECR, Terraform/AWS CDK, GitHub Actions/CodeBuild + Argo CD**.  
- **Networking & security:** Multi‑AZ **VPC**, IAM least privilege, **KMS**, **ACM** certs, **SSM Parameter Store / Secrets Manager**.

### Retention & cost posture (simple, defensible)
- **Metrics:** 10s / **14d (hot)** → **1–5m / 180+d (warm)** → **5m/1h / ~13mo (cold/S3)**.  
- **Logs:** **7d** hot / **30d** warm / **365d** cold, tokenized at the edge.  
- **Budget:** plan **~500 GB/day/region hot** (metrics) for index/replicas; scale object storage for warm/cold; monitor compactor/store‑gateway health.

### SLOs that keep us honest
- **Freshness (write→read):** **p99 ≤ 10 s**.  
- **Ingest TTFB:** **p99 ≤ 250–350 ms** at 1×–3× load.  
- **Query SLOs:** **p95 ≤ 2 s** (≤12 h), **p99 ≤ 10 s** (7–30 d).  
- **Data completeness:** **≥99.9%** of expected series per 5‑min window.  
_Dashboards display current freshness and data range so operators know when graphs are stale._

### How we prove 1M CCU readiness (acceptance gates)
- **Ingest soak:** ≥**200k samples/s** global for **2–6 h**; **zero loss**, write→read **p95 < 30 s**.  
- **Bursts:** **1×/3×/5×** for 15 min; backpressure engages; backlog drains < 30 min; gameplay SLIs intact.  
- **Query load:** ~**200 concurrent viewers**; meet query SLOs; cache hit **≥ 80%**.  
- **Chaos:** Kill an **AZ** worth of ingesters/queriers or a broker; **no data loss**, freshness recovers **< 2 min**.  
- **Replay:** Pause stream partitions **10–20 min**; clean catch‑up, no out‑of‑order blowups.  
- **Cost/SLO guardrails:** Autoscale on **freshness/query p95/cache hit**, not CPU; object‑store ops/query within budget.

### Rationale & trade-offs
- **Prometheus‑compatible, object‑store‑backed TSDB** (AMP/Mimir) fits low‑cardinality, high‑throughput metrics with PromQL ubiquity.  
- **Edge histograms** preserve p95/p99 accuracy with tiny payloads and bounded series; avoids per‑event firehoses & PII risk.  
- **Streaming buffer** (Kinesis/MSK) is critical for bursts, replay, and multi‑sink fan‑out without coupling game servers to TSDB internals.  
- **Managed first** (AMP, OpenSearch, X‑Ray, AMG) to reduce undifferentiated ops; **self‑manage Mimir/EKS** only when tenancy/knobs demand it.  
- **Tenancy, quotas, security** ensure one team’s mistake can’t take the platform down or leak identity into metrics.

### Risks & mitigations
- **Cardinality creep →** Label allowlist + per‑tenant series/sample limits + CI lints + runtime rejects.  
- **Query hotspots →** Recording rules, query sharding, result caches, dashboard budgets.  
- **Compactor/store‑gateway lag →** Monitor compaction backlog & bucket‑index sync; size compactor; merge to bigger blocks.  
- **Bursty releases/events →** Stream buffering + backpressure order (shed verbose logs first) + capacity headroom.  
- **Cost drift →** Track bytes‑added/day by tier, cache‑hit SLOs, object‑store ops/query alarms; autoscale tied to user‑visible SLOs.

---

## 1. Scope & Non-Goals

### 1.1 In Scope
- Metrics ingestion, storage, query, dashboards  
- Logs pipeline (tokenization, hot/warm/cold)  
- Tracing (optional)  
- Multi‑region deployment (list regions)  
- Tenancy & quotas (multi‑team/multi‑title)  
- Security & compliance essentials  
- Capacity tests & readiness gates  

### 1.2 Out of Scope (see Improvements)
- Per‑player metrics/PII in metrics  
- Cross‑cloud portability  
- Fully managed APM with code profiling (future)  
- Deep eBPF network controls (future)  

### 1.3 Improvements Roadmap (90/180/365-day)
**90 days (low risk, high ROI)**  
- Recording‑rule catalog v1 (standard p95/p99 rollups per service).  
- Query budgets & slow‑query killer (protect caches during incidents).  
- Autoscaling on freshness/query p95/cache‑hit (not CPU).  
- Immutable images for agents; SBOM + signed AMIs; start‑time SLO tracked.

**180 days (deeper posture)**  
- Cilium + Hubble for L3–L7 flow metrics; eBPF summaries (runqlat, tcpretrans) budgeted ≤3% CPU.  
- Result cache + query sharding on long ranges (7–30d); compactor sizing for bigger merged blocks.  
- Tenant self‑service portal (limits, dashboards, tokens) with guardrails.  
- Cost watchdog: object‑store ops/query and OpenSearch hot shards alarms + weekly FinOps review.

**365 days (strategic bets)**  
- Firecracker microVM sidecar for agents on hot hosts (blast‑radius control).  
- Multi‑region active/standby for metrics plane (cold failover, data loss budget < X).  
- Per‑tenant KMS keys (BYOK) for regulated studios; ABAC on dashboards.

**KPIs to show improvement landed**  
- p95 dashboard latency (≤12h); Write→read age p99; Cache hit %; Compactor backlog; Object‑store GETs/query; Cost per 1k samples; % fleets on signed image; Mean time to rollback.

---

## 2. Assumptions / Constraints & Design Methodology
    
### 2.1 Workload & Resource Analysis
Start with a player reality—1,000,000 CCU roughly split across NA/EU/APAC—because traffic drives shards, per-region quotas, and AZ spread. Converting load into hosts (~200 CCU/server ⇒ ~5,000 servers ≈ 1,700/region) makes capacity tangible and lets us budget exporter series, CPU/disk/NIC via the USE method. A 10 s emission cadence (tightened to 5 s during incidents) balances fidelity and overhead so we can see issues without creating them. This makes the rest of the design concrete and testable.

- **Peak population:** 1,000,000 CCU, ~even split across NA/EU/APAC.  
  - *Why:* anchors shard counts, per‑region quotas, and AZ spread.  
  - *Size/verify:* regional CCU telemetry or historical curves (assume 35/35/30 if unknown).
  - *Source:* - [Google SRE — “Monitoring Distributed Systems”](https://sre.google/sre-book/monitoring-distributed-systems/)

- **Gameserver density:** ~200 CCU/server ⇒ ~5,000 servers (~1,700/region).  
  - *Why:* converts CCU into hosts → exporter/series budgets & autoscaling units.  
  - *Size/verify:* match sizes + CPU headroom per game mode; adjust after soak.
  - *Source:* - [Brendan Gregg — The USE Method](https://www.brendangregg.com/usemethod.html)

- **Emission cadence:** 10 s steady; 5 s during incidents.  
  - *Why:* smooth charts at low cost; bump resolution only when needed.  
  - *Size/verify:* edge flags; exporter CPU < 1–2% at 5 s.
  - *Source:* - [Google SRE — “Monitoring Distributed Systems”](https://sre.google/sre-book/monitoring-distributed-systems/)

### 2.2 Signal Shapes
Emit counters + histograms (no per-event series) under a strict label allowlist and a ~300 active series/server budget. Histograms yield accurate p95/p99 while preventing cardinality blowups or PII leaks. Metrics ingestion and query cost are dominated by series count; this keeps the system operable at 1M CCU.

- **Edge aggregation only:** counters + (exponential) histograms (no per‑event series).  
  - *Why:* p95/p99 without per‑event explosion.  
  - *Size/verify:* compare histogram quantiles vs. raw‑sample quantiles on a canary.
  - *Sources:* - [Prometheus — Histogram best practices](https://prometheus.io/docs/practices/histograms/)  
  - `histogram_quantile()` in PromQL (see same doc)  
  - [OTel — Exponential histograms (overview)](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exponentialhistogram)

- **Strict label policy:** allow `{region, az, cluster, shard_id, instance_type, build_id, queue, asn_bucket}`; **forbid** `{player_id, raw_ip, request_id, free-text}`.  
  *Why:* avoid high cardinality & PII.
  *Size/verify:* CI lint + edge-time reject; alert on series growth.  
  *Sources:*  - [Prometheus — Naming & labels guidance](https://prometheus.io/docs/practices/naming/) - [Prometheus — Cardinality advice](https://prometheus.io/docs/practices/instrumentation/)

- **Series budget:** ≈ **300 active series/server**.  
  - *Why:* linear scaling with fleet; predictable storage & query cost.  
  - *Size/verify:* exporter self‑metric `active_series_total`; gate rollouts when > budget.
  *Source:* - [Prometheus — Naming & labels guidance](https://prometheus.io/docs/practices/naming/)

- **RED framing:** Rate, Errors, Duration for login → matchmaking → join.  
  *Source:* - [Grafana — The RED Method](https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/)

### 2.3 Ingestion & Transport
From the series budget we derive ~150k samples/s global (~50k/s/region) and size for ≥200k/s headroom. We design for 1×/3×/5× bursts, apply backpressure, and prioritize gameplay SLIs so spikes don’t cascade. A durable, quota-aware pipeline keeps data loss and dashboard lag off the critical path.

- **EPS math:** `5,000 servers × 300 series ÷ 10 s ≈ 150k samples/s (global)` → **plan ≥ 200k/s** target with headroom (≈50k/s per region).  
  - *Why:* sizes ingest concurrency, WAL throughput, and broker partitions.  
  - *Verify:* synthetic **1×/3×/5×** load; watch accept rate & WAL latency.  
- **Burst posture:** test **1× / 3× / 5×** (baseline/patch/mass‑event).  
  - *Why:* ensure spikes don’t cascade; backlog drains cleanly.  
  - *Verify:* lag‑based throttling/backpressure; prove replay.
  *Source:* - [Kafka performance tuning — tips & best practices (AutoMQ wiki)](https://github.com/AutoMQ/automq/wiki/Kafka-Performance-Tuning%3A-Tips-%26-Best-Practices)

- **Backpressure order:** shed non‑critical (verbose logs) first; protect gameplay SLIs.  
  *Sources:* - [SRE Workbook — Managing Load](https://sre.google/workbook/managing-load/) - [SRE Book — Handling Overload](https://sre.google/sre-book/handling-overload/)


### 2.4 Storage & Retention
At ~15–20 B/sample, 150k/s × 86,400 ≈ 12.96B samples/day yields ~200–260 GB/day global (hot); we budget ~500 GB/day per region (hot) for index/replica headroom. Tier metrics 10 s for ~14 d (hot) → 1–5 m for ~180+ d (warm) → 5 m/1 h to ~13 mo (cold, S3/Parquet), and keep logs separate (7 d / 30 d / 365 d) with PII tokenized. This is where cost, reliability, and query speed meet.

- **Capacity math (metrics, hot):** at ~15–20 B/sample, `150k/s × 86,400 s = 12.96B samples/day` ⇒ **~200–260 GB/day global**; budget **~500 GB/day/region** (hot) incl. index/replicas.  
  - *Why:* avoid surprise SSD/S3 bills; ensure compactions keep up.  
- **Retention/tiers (metrics):** **10 s** for **7–14 d** (hot) → **1–5 m** for **30–90 d+** (warm) → **5 m / 1 h** to **≈13 mo** (cold, S3/Parquet).  
  - *Why:* long horizons without runaway cost; queries auto‑pick rollups.  
  - *Verify:* recording‑rules usage; query hit ratios; compactor/store‑gateway health.  
- **Logs:** **7 d hot (indexed)** / **30 d warm** / **365 d cold (S3)**; tokenize PII at the edge.  
  - *Why:* investigations & compliance without polluting the metrics store.  
- **Advanced (when ready):** compactor sizing (bigger merged blocks), query sharding + result cache, remote‑write tuning, columnar cold formats for Athena/Presto.

### 2.5 Query & Visualization
- **Query SLOs:** **p95 ≤ 2 s** (≤12 h), **p99 ≤ 10 s** (7–30 d, downsampled).  
  - *Why:* on‑call usability during incidents.  
  - *Verify:* precompute rollups; cap range vectors; cache; throttle costly queries.  
- **Dashboard standards:** Golden Signals per service (latency/traffic/errors/saturation) + gameplay SLIs.  
  - *Why:* standard triage surface; operator muscle memory.

### 2.6 SLOs & Freshness
- **Freshness (write→read):** **p99 ≤ 10 s**.  
  - *Why:* dashboards reflect reality quickly; guides flush/compaction policy.  
  - *Verify:* `ingest_to_query_age_seconds` histogram + burn‑rate alerts.  
- **Ingest TTFB:** **p99 ≤ 250–350 ms @ 1×–3×**.  
  - *Why:* early warning for queueing/TLS/connect issues.  
  - *Verify:* client timers + server logs; alert on sustained drift.  
- **Optional reporting add‑ons:**  
  - Data completeness SLO: **≥99.9%** of expected time series present per 5‑min window.  
  - Dashboard staleness indicator: show current write→read age + data time range on each board.

### 2.7 Tenancy & Quotas
- **Policy:** split EPS by `{region, tenant}`; enforce quotas at edge → broker → ingesters → queriers; on exceed, **HTTP 429 + Retry‑After**; degrade non‑critical classes first.  
  - *Why:* noisy‑neighbor isolation; predictable capacity.  
- **Resource controls:** priorities (shares/weights) and limits (bandwidth/ceilings) per CPU/memory/disk I/O/network; qdiscs/BPF for shaping.  
- **Cardinality controls:** per‑tenant **series** & **samples/s** limits; dashboards for series growth; CI lint to block forbidden labels.  
  - *Why:* prevent TSDB blow‑ups; complements OS‑level fairness.

### 2.8 Security & Compliance (Essentials)
- **Privacy by design:** no PII in metrics (schema allowlist + CI lints + runtime rejection); treat logs as sensitive; tokenize at collection.  
- **Defense in depth:** isolate by tenant + region (logical IDs + physical S3 prefixes/buckets; per‑env KMS keys).  
- **Fail‑safe defaults:** drop unknown labels/fields; deny on missing auth; short‑lived creds/certs.  
- **Provable controls:** violations alert; admin/API actions are tamper‑evident (WORM S3).  
- **Operational simplicity:** IAM/KMS‑managed primitives; immutable, signed images; SSH disabled (SSM only).  
- **Day‑1 controls checklist:** label allowlist; mTLS agent↔collector↔broker↔store; per‑tenant scopes; KMS at rest; private subnets/WAF/strict SGs; secrets in SM/PS w/ ≤90‑day rotation; documented retention & deletion.

### 2.8.1 Principles
- **No PII in metrics** (enforced at edge).  
- **Tokenize/redact logs** at collection.  
- **mTLS everywhere; KMS at rest; least‑privilege IAM**.  
- **Immutable images; signed artifacts; SSH disabled (SSM only)**.  
- **Audit logs to S3 object‑lock** (WORM).

### 2.8.2 Day-1 Controls (checklist)
- Label allowlist & edge reject.  
- mTLS agent↔collector↔broker↔store (short‑lived certs).  
- Per‑tenant auth scopes/RBAC.  
- KMS keys per environment (per‑tenant optional).  
- Private subnets/WAF/strict SGs.  
- Secrets in SM/PS; rotation ≤90 d.  
- Retention & deletion process documented.  
- Residency stance (e.g., default CA regions; replication policy).

### 2.8.3 Minimal framework alignment
- **NIST 800‑53 / ISO 27001:** Access control, Identification & Auth, System & Communications Protection, Audit & Accountability, Config Mgmt.  
- **BC FOIPPA (if applicable):** default telemetry to Canada regions; document any cross‑border replication and compensating controls.

### 2.9 Capacity Tests (Pass/Fail Gates)
**Goal:** convert assumptions into verifiable gates using production‑like label sets & histogram buckets.

| Test | Why | Setup | Pass / Fail |
|---|---|---|---|
| **T0: Env parity & canary** | Proves config/image parity before heavy tests | 1% traffic mirror; canary tenant with real labels | **Pass:** parity dashboards all green; no policy rejects. **Fail:** any reject or >1% divergence |
| **T1: Ingest soak (≥1.3×)** | Verifies write path capacity & durability | Synthetic producers push **≥200k samples/s global** for 2–6 h | **Pass:** zero loss; write→read p95 < 30 s, p99 ≤ 10 s; WAL replay < 5 min. **Fail:** drops/WAL stall/SLO breach |
| **T2: Burst (1×/3×/5×)** | Patch/match‑start resilience | 15‑min bursts to 1× / 3× / 5× baseline with realistic label churn | **Pass:** backpressure engages; backlog drains < 30 min; no core SLI loss. **Fail:** core SLI loss/backlog plateau |
| **T3: Query load** | Operator UX under pressure | ~200 concurrent viewers; mixed ranges (≤12 h and 7–30 d) | **Pass:** p95 ≤ 2 s (≤12 h), p99 ≤ 10 s (7–30 d); cache hit ≥ 80%. **Fail:** cache thrash/misses |
| **T4: Chaos (AZ/broker loss)** | Fault‑tolerance & recovery | Kill one AZ worth of ingesters/queriers or a broker node | **Pass:** zero data loss; freshness recovers < 2 min. **Fail:** gaps/prolonged staleness |
| **T5: Backpressure & replay** | Durability and orderly catch‑up | Pause stream partitions 10–20 min; resume | **Pass:** buffer + prioritized shed; clean catch‑up; no out‑of‑order explosions. **Fail:** dead‑letter growth/lag stuck |
| **T6: Data completeness** | “Are we seeing all expected series?” | Tenant emits known count of series (±1%) per shard | **Pass:** ≥99.9% present per 5‑min window. **Fail:** sustained missing‑series |
| **T7: Cardinality guard** | Prevent index/WAL blow‑ups | Introduce “bad” metric (forbidden label) in staging | **Pass:** edge reject + alert ≤ 1 min; 0 new store series. **Fail:** any acceptance |
| **T8: Cost/SLO guardrails** | Ensure scaling tracks outcomes | Scale during T1–T3 | **Pass:** autoscaling driven by freshness / query p95 / cache hit; object‑store ops/query within budget. **Fail:** SLO breach during scale |

**Run order:** T0 → T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8 (overlapping where practical).  
**Artifacts:** dashboards (freshness, accept rate, compactor lag, cache hit, query durations), producer sent/ack counts, 429/Retry‑After stats, limits snapshot, chaos notes.

> **Notes that keep you honest**  
> • Data shape matters: always use real label sets & histogram buckets in load gen.  
> • Measure at user boundaries: dashboard timers + write→read age are the truth.  
> • Scale to SLOs, not utilization: autoscaling inputs are freshness, query p95, cache hit.  
> • Time‑box soak: min **2 h**, ideal **6 h**, to expose compaction/GC/eviction cycles.

---

## 8. Architecture (AWS)

> _Add diagram(s) here._

### 8.1 Components & AWS Services
| Layer | Primary Services | Role |
|---|---|---|
| Agents / Edge | Game exporter, Node Exporter, ADOT, Fluent Bit | Emit metrics (counters/histograms), tokenize/redact logs, TLS, batching |
| Transport | Kinesis Data Streams (or MSK), Kinesis Firehose | Durable buffer, burst absorption; logs → OpenSearch & S3 |
| Metrics Store | Amazon Managed Prometheus (AMP) _or_ Grafana Mimir on EKS + S3 | PromQL TSDB, object‑store backed, multi‑tenancy limits |
| Logs Store | Amazon OpenSearch Service, S3 (+ Glue/Athena) | Hot search, warm/cold archive, analytics |
| Tracing (opt.) | AWS X‑Ray _or_ Grafana Tempo | Distributed traces |
| Dashboards | Amazon Managed Grafana (AMG) | Visualization, RBAC, alerting |
| Foundations | EKS, VPC, ECR, KMS, IAM, CloudWatch, SSM, WAF | Compute/network/security/foundation |
| IaC / CI/CD | Terraform/CDK, GitHub Actions/CodeBuild, Argo CD | Reproducible delivery |

### 8.2 Data Flow (high level)
1. Agents emit counters + histograms every 10 s (5 s during incidents).  
2. Metrics: ADOT → Kinesis/MSK → AMP/Mimir.  
3. Logs: Fluent Bit → Firehose → OpenSearch (hot) & S3 (raw/Parquet).  
4. Grafana queries AMP/Mimir/OpenSearch; alerts route via CloudWatch/PD/Slack.

---

## 9. Capacity & Storage Planning

### 9.1 Ingest & Storage
- **EPS baseline:** ~150k samples/s (**≥200k/s target**).  
- **Bytes/sample (plan):** ~15–20 B amortized.  
- **Daily hot metrics (global):** ~200–260 GB/day (**budget: ~500 GB/day/region** incl. index/replicas).

### 9.2 Retention (fill with final choices)
- **Metrics:** Hot 10s **7–14d** → Warm 1–5m **30–90d (up to 180d)** → Cold 5m/1h **~13mo (S3)**.  
- **Logs:** **7d** hot / **30d** warm / **365d** cold (S3).

### 9.3 S3 Lifecycle (concept)
- Metrics blocks: **30d → IA**; **180d → Glacier**; **expire 400d**.  
- Logs: **30d → IA**; **365d → Glacier**; **expire 730d**.

---

## 10. SLOs, Alerts & Dashboards

### 10.1 SLOs
- **Freshness:** write→read **p99 ≤ 10s**.  
- **Query latency:** **p95 ≤ 2s (≤12h)**, **p99 ≤ 10s (7–30d)**.  
- **Ingest TTFB:** **p99 ≤ 250–350ms** @ 1×–3×.

### 10.2 Alert Policy (examples to instantiate)
- Burn rate for player‑facing SLIs.  
- Freshness breach (>10s p99).  
- Query p95/p99 regressions.  
- Cardinality growth / limits approaching.  
- Compactor lag / object‑store errors.

### 10.3 Dashboard Standards (add links/screens later)
- Golden Signals per service.  
- Gameplay SLIs.  
- Infra/Network health.  
- Cost & storage (bytes/day by tier, cache hit, read amplification).

---

## 11. Tenancy, Quotas & Fairness

- **Tenant model:** (teams/titles listed).  
- **Per‑tenant quotas:** EPS, samples/s, max series, query limits.  
- **Enforcement points:** edge → stream → ingesters → query‑frontend.  
- **Overage behavior:** HTTP **429 + Retry‑After**; shed non‑critical classes first.  
- **Cardinality guard:** dashboards + kill switches; CI lints schema.  
- **OS fairness controls:** CPU shares/bandwidth; memory soft/hard; blkio weights/throttles; qdiscs/BPF shaping.

---

## 12. Security & Compliance (Essentials)

### 12.1 Principles (recap)
- No PII in metrics; tokenize logs at collection; mTLS; KMS; least privilege; immutable & signed images; audit logs to S3 WORM.

### 12.2 Day-1 Checklist
- [ ] Label allowlist & edge reject in exporters/collectors  
- [ ] mTLS chain (agents↔collectors↔brokers↔stores), short‑lived certs  
- [ ] Per‑tenant scopes & RBAC in gateway/store  
- [ ] KMS keys per environment (per‑tenant optional)  
- [ ] Private subnets, strict SGs, WAF on public UIs  
- [ ] Secrets in SSM/Secrets Manager; rotation ≤90d  
- [ ] Retention & deletion process documented  
- [ ] Residency stance and replication policy documented

---

## 13. Build & Implementation Plan

### 13.1 Environments
- **Dev / Staging / Prod:** parity, canary tenants, synthetic load toggles.

### 13.2 Delivery Milestones (fill dates)
1. Architecture ready (docs/diagrams/limits) — **TBD**  
2. Foundations (VPC, EKS or AMP, S3, IAM, KMS) — **TBD**  
3. Pipelines up (Kinesis/Firehose/OpenSearch) — **TBD**  
4. Agents baked (exporters, ADOT, Fluent Bit) — **TBD**  
5. Dashboards & alerts (MVP) — **TBD**  
6. Capacity tests (T0–T8) — **TBD**  
7. Security sign‑off — **TBD**  
8. Go‑live — **TBD**

### 13.3 RACI (example)
| Task | Eng | SRE | Sec | PM | Owner |
|---|---:|---:|---:|---:|---:|
| Network / VPC / SGs | R | A | C | I |  |
| AMP/Mimir setup | R | A | C | I |  |
| Logs pipeline (OS/S3) | R | A | C | I |  |
| Dashboards/Alerts | R | A | C | I |  |
| Capacity tests | A | R | C | I |  |
| Security controls | C | R | A | I |  |

---

## 14. Operations

### 14.1 Runbooks (link/add later)
- Freshness breach  
- Query slowness  
- Cardinality spike  
- AZ/broker failure  
- Data loss suspected

### 14.2 SRE On-call
- **Coverage model:** _(fill)_  
- **Escalation path:** _(fill)_  
- **Status comms:** Slack / Email / StatusPage

### 14.3 Change Management
- IaC + PR reviews; blue/green or canary for agents & pipelines; rollback criteria.

---

## 15. Capacity Tests & Readiness Gates

**Ship on measured reality. Use production‑like labels & histogram buckets.**

| Test | Why | Setup | Pass |
|---|---|---|---|
| **T0 Parity/Canary** | Validate env parity | 1% mirror | No rejects; <1% divergence |
| **T1 Ingest Soak (≥1.3×)** | Write path capacity | ≥200k samples/s for 2–6h | 0 loss; write→read p95 <30s, p99 ≤10s |
| **T2 Burst 1×/3×/5×** | Patch/match resilience | 15‑min spikes | Backpressure OK; drains <30m |
| **T3 Query Load** | Operator UX | ~200 viewers | p95 ≤2s (≤12h), p99 ≤10s (7–30d); cache ≥80% |
| **T4 Chaos (AZ/Broker)** | Fault tolerance | Kill AZ or broker | 0 loss; freshness recovers <2m |
| **T5 Replay** | Durability & catch‑up | Pause partitions 10–20m | Clean catch‑up; no OOO blowups |
| **T6 Completeness** | Expected series present | Known count/tenant | ≥99.9% in 5‑min windows |
| **T7 Cardinality Guard** | Prevent blowups | Bad label in staging | Edge reject + alert ≤1m |

**Hard ship gates:** T1, T3, T4, T5.  
**Artifacts:** dashboards, logs, limits snapshot, chaos notes.

---

## 16. Cost & FinOps (initial)

- **Major cost drivers:** S3 storage & requests, query/read ops, OpenSearch hot nodes, Kinesis/MSK throughput.  
- **Levers:** downsampling, lifecycle policies, cache hit ratio, query limits, log sampling, cold formats (Parquet/ORC).  

**Monthly estimate placeholders (fill post‑POC):**  
- Metrics hot/warm: **$ ___**  
- S3 storage + requests: **$ ___**  
- OpenSearch hot/warm/cold: **$ ___**  
- Kinesis/MSK: **$ ___**  
- Grafana/AMP/EKS: **$ ___**

---

## 17. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---:|---|
| Cardinality explosion | Query/ingest outage | M | CI lint; per‑tenant limits; kill switch |
| Compactor lag | Slow historical queries | M | Size compactor; monitor; S3 health alarms |
| Cost overrun | Budget breach | M | Downsample; lifecycle; query controls |
| Residency constraints | Non‑compliance | L/M | Canada‑first, disable cross‑Region replication, non‑MR KMS |
| 3rd‑party infra gaps | Blind spots | M | Edge QoE metrics; external probes; contracts |

---

## 18. Open Questions
- Regions final?  
- AMP vs Mimir decision?  
- Tracing required at day‑1?  
- Residency/contractual constraints for specific tenants?  
- On‑call coverage and SLAs?

---

## 19. Appendices (to attach later)
- **A.** Architecture diagrams (current, target)  
- **B.** Label schema & lint rules  
- **C.** Recording rules catalog  
- **D.** Alert catalog (burn rates, freshness, query)  
- **E.** S3 lifecycle policies (metrics/logs)  
- **F.** Runbooks (R1–R4)  
- **G.** Test reports (T0–T7)  
- **H.** Security control matrix (NIST/ISO mapping)

---

## 20. Improvements Adornment (reference-only, out of scope for Day-1)

### 20.1 Immutable Golden Images (deterministic rollouts)
- Pre‑baked OS images with exporters/ADOT/Fluent Bit, SBOMs, signatures, read‑only FS, cloud‑init last‑mile.  
- Health gate `/ready?exporters=ok&wg=ok&xdp=ok`; start‑time SLO: **p95 power→metrics < 60s**.  
- Rollouts via ASG instance‑refresh; fast rollback by image version.

### 20.2 Cilium + Hubble & eBPF summaries
- L3–L7 flow visibility; eBPF histograms (runqlat, tcpretrans, biolatency) **≤3% CPU** budget; XDP drop/shape junk traffic early.  
- Dashboards: overlay_xdp_drops_total, overlay_peer_rtt_ms, overlay_peer_loss_ppm.

### 20.3 Firecracker microVM sidecars (agent isolation)
- ADOT/Fluent Bit/exporters inside microVMs; dedicate **0.5–1 vCPU** & RAM slice; independent lifecycle; near‑container boot times **(<5s P95)**.

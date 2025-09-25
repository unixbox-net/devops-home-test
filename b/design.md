# Reporting & Observability Platform (AWS)

**Purpose:** Define scope, design, build, implementation, and operations for a metrics/logs/tracing platform capable of supporting ~**1,000,000** concurrent clients with low‑latency reporting.

---

## Table of Contents

- [Document Control](#document-control)
- [Executive Summary — 1M-CCU Metrics & Reporting Platform (AWS)](#executive-summary--1m-ccu-metrics--reporting-platform-aws)
  - [Assumptions That Shape the Design](#assumptions-that-shape-the-design)
  - [What Data the Cluster Holds](#what-data-the-cluster-holds)
  - [How It Stays Performant (by Construction)](#how-it-stays-performant-by-construction)
  - [Technologies (AWS-Native, With Escape Hatches)](#technologies-aws-native-with-escape-hatches)
  - [Retention & Cost Posture (Simple, Defensible)](#retention--cost-posture-simple-defensible)
  - [SLOs That Keep Us Honest](#slos-that-keep-us-honest)
  - [How We Prove 1M CCU Readiness (Acceptance Gates)](#how-we-prove-1m-ccu-readiness-acceptance-gates)
  - [Rationale & Trade-offs](#rationale--trade-offs)
  - [Risks & Mitigations](#risks--mitigations)
- [1. Scope & Non-Goals](#1-scope--non-goals)
  - [1.1 In Scope](#11-in-scope)
  - [1.2 Out of Scope (See Improvements)](#12-out-of-scope-see-improvements)
  - [1.3 Improvements Roadmap (90/180/365-Day)](#13-improvements-roadmap-90180365-day)
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
    - [2.8.2 Day-1 Controls (Checklist)](#282-day-1-controls-checklist)
    - [2.8.3 Minimal Framework Alignment](#283-minimal-framework-alignment)
  - [2.9 Capacity Tests (Pass/Fail Gates)](#29-capacity-tests-passfail-gates)
- [3. Architecture (AWS)](#3-architecture-aws)
  - [3.1 Components & AWS Services](#31-components--aws-services)
  - [3.2 Data Flow (High Level)](#32-data-flow-high-level)
- [4. Capacity & Storage Planning](#4-capacity--storage-planning)
  - [4.1 Ingest & Storage](#41-ingest--storage)
  - [4.2 Retention (Finalize Choices)](#42-retention-finalize-choices)
  - [4.3 S3 Lifecycle (Concept)](#43-s3-lifecycle-concept)
- [5. SLOs, Alerts & Dashboards](#5-slos-alerts--dashboards)
  - [5.1 SLOs](#51-slos)
  - [5.2 Alert Policy (Examples)](#52-alert-policy-examples)
  - [5.3 Dashboard Standards](#53-dashboard-standards)
- [6. Tenancy, Quotas & Fairness](#6-tenancy-quotas--fairness)
- [7. Security & Compliance (Essentials)](#7-security--compliance-essentials)
  - [7.1 Principles (Recap)](#71-principles-recap)
  - [7.2 Day-1 Checklist](#72-day-1-checklist)
- [8. Build & Implementation Plan](#8-build--implementation-plan)
  - [8.1 Environments](#81-environments)
  - [8.2 Delivery Milestones](#82-delivery-milestones)
  - [8.3 RACI (Example)](#83-raci-example)
- [9. Operations](#9-operations)
  - [9.1 Runbooks](#91-runbooks)
  - [9.2 SRE On-Call](#92-sre-on-call)
  - [9.3 Change Management](#93-change-management)
- [10. Capacity Tests & Readiness Gates](#10-capacity-tests--readiness-gates)
- [11. Cost & FinOps (Initial)](#11-cost--finops-initial)
- [12. Risks & Mitigations](#12-risks--mitigations)
- [13. Open Questions](#13-open-questions)
- [14. Appendices](#14-appendices)
- [15. Improvements Adornment (Reference-Only)](#15-improvements-adornment)
  - [15.1 Immutable Golden Images](#151-immutable-golden-images)
  - [15.2 Cilium + Hubble & eBPF Summaries](#152-cilium--hubble--ebpf-summaries)
  - [15.3 Firecracker MicroVM Sidecars](#153-firecracker-microvm-sidecars)

---
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
  - *Sources:* - [Prometheus — Naming & labels guidance](https://prometheus.io/docs/practices/naming/)
  - [Prometheus — Cardinality advice](https://prometheus.io/docs/practices/instrumentation/)

- **Series budget:** ≈ **300 active series/server**.  
  - *Why:* linear scaling with fleet; predictable storage & query cost.  
  - *Size/verify:* exporter self‑metric `active_series_total`; gate rollouts when > budget.
  - *Source:* - [Prometheus — Naming & labels guidance](https://prometheus.io/docs/practices/naming/)

- **RED framing:** Rate, Errors, Duration for login → matchmaking → join.
  - *Source:* - [Grafana — The RED Method](https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/)

### 2.3 Ingestion & Transport
From the series budget we derive ~150k samples/s global (~50k/s/region) and size for ≥200k/s headroom. We design for 1×/3×/5× bursts, apply backpressure, and prioritize gameplay SLIs so spikes don’t cascade. A durable, quota-aware pipeline keeps data loss and dashboard lag off the critical path.

- **EPS math:** `5,000 servers × 300 series ÷ 10 s ≈ 150k samples/s (global)` → **plan ≥ 200k/s** target with headroom (≈50k/s per region).  
  - *Why:* sizes ingest concurrency, WAL throughput, and broker partitions.  
  - *Verify:* synthetic **1×/3×/5×** load; watch accept rate & WAL latency.  
- **Burst posture:** test **1× / 3× / 5×** (baseline/patch/mass‑event).  
  - *Why:* ensure spikes don’t cascade; backlog drains cleanly.  
  - *Verify:* lag‑based throttling/backpressure; prove replay.
  - *Source:* - [Kafka performance tuning — tips & best practices (AutoMQ wiki)](https://github.com/AutoMQ/automq/wiki/Kafka-Performance-Tuning%3A-Tips-%26-Best-Practices)

- **Backpressure order:** shed non‑critical (verbose logs) first; protect gameplay SLIs.
- *Sources:* - [SRE Workbook — Managing Load](https://sre.google/workbook/managing-load/)
- [SRE Book — Handling Overload](https://sre.google/sre-book/handling-overload/)


### 2.4 Storage & retention
At **~15–20 B/sample**, `150k/s × 86,400 ≈ 12.96B samples/day` yields **~200–260 GB/day global (hot)**; we budget **~500 GB/day per region (hot)** for index/replica headroom. Tier metrics **10 s for ~14 d (hot) → 1–5 m for ~180+ d (warm) → 5 m/1 h to ~13 mo (cold, S3/Parquet)**, and keep logs separate (**7 d / 30 d / 365 d**) with PII tokenized. This is where cost, reliability, and query speed meet.

- **Capacity math:** as above; plan **~500 GB/day/region (hot)** incl. index/replicas.  
  *Why:* avoid surprise SSD/S3 bills; ensure compactions keep up.

- **Retention/tiers (metrics):** 10 s for 7–14 d (hot) → 1 m for 30–90 d (warm) → 5 m / 1 h for ~13 mo (cold).  
  *Why:* long horizons without runaway cost; dashboards auto-pick rollups.  
  *Verify:* recording rules in place; watch hit ratios.  
  *Refs:*  
  - [Prometheus — Histogram best practices](https://prometheus.io/docs/practices/histograms/)  
  - [Prometheus — Recording rules](https://prometheus.io/docs/practices/rules/)

- **Logs:** **7 d hot (indexed) / 30 d warm / 365 d cold (S3)**; tokenize PII at edge.  
  *Why:* investigations & compliance without polluting the metrics store.

**Basics**  
- [Prometheus histograms & quantiles](https://prometheus.io/docs/practices/histograms)  
- [Prometheus storage model (blocks, WAL, retention)](https://prometheus.io/docs/prometheus/latest/storage/)  
- [Mimir store-gateway & bucket index](https://grafana.com/docs/mimir/latest/references/architecture/components/store-gateway/)  
- Golden Signals: [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) and [Managing Load](https://sre.google/workbook/managing-load/)

**Advanced**  
- Bigger merged blocks via compactor (fewer indexes to scan, cheaper historical reads): [Mimir compactor](https://grafana.com/docs/mimir/latest/references/architecture/components/compactor/)  
- Query sharding + result cache: [Mimir query-frontend](https://grafana.com/docs/mimir/latest/references/architecture/components/query-frontend/)  
- Right-size histogram strategy (server-side quantiles):  
  [Prometheus histograms](https://prometheus.io/docs/concepts/metric_types/#histogram) and  
  [histogram best practices](https://prometheus.io/docs/practices/histograms/)  
- Remote-write tuning (queues, batch, retry/backoff, relabel):  
  [Remote write best practices](https://prometheus.io/docs/practices/remote_write/) and  
  [remote_write configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#remote_write)

### 2.5 Query & visualization
Set query SLOs **p95 ≤ 2 s (≤12 h)** and **p99 ≤ 10 s (7–30 d)**, achieved via recording rules, caching, and query limits. Dashboards follow Golden Signals so on-call can triage quickly. Slow dashboards during incidents are as bad as no dashboards.

- **Query SLOs:** p95 ≤ 2 s (≤12 h), p99 ≤ 10 s (7–30 d).  
  *Why:* on-call usability.  
  *Verify:* precompute rollups; cache; cap range vectors; throttle costly queries.  
  *Refs:*  
  - [Amazon Managed Service for Prometheus — Query insights & controls](https://docs.aws.amazon.com/prometheus/latest/userguide/query-insights-control.html)  
  - [AMP — Understanding query costs](https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-costs.html)

- **Dashboard content:** latency/traffic/errors/saturation panels per service.  
  *Why:* standard triage surface.  
  *Ref:* [Google SRE — Four Golden Signals](https://sre.google/sre-book/monitoring-distributed-systems/)

### 2.6 SLOs & freshness
Commit to **write→read p99 ≤ 10 s** and **ingest TTFB p99 ≤ 250–350 ms @ 1×–3×**, with burn-rate alerts on breaches. Freshness determines whether dashboards reflect reality; these translate engineering into player-visible guarantees and anchor capacity/scaling to measurable outcomes.

- **Ingest TTFB:** p99 ≤ 250–350 ms @ 1×–3×.  
  *Why:* early warning for queueing/TLS/connect issues.  
  *Verify:* client timers + server logs; alert on sustained drift.  
  *Refs:*  
  - Gregg, *Systems Performance (2e)* — Ch. 2.3.1 (pp. 24–25)  
  - Ch. 10.5.4 (pp. 528–529)  
  - Ch. 10.6 (socket first-byte tools)

- **Freshness (write→read):** p99 ≤ 10 s.  
  *Why:* dashboards reflect reality; guides flush/compaction policy.  
  *Verify:* `ingest_to_query_age_seconds` histogram + burn-rate alerts.  
  *Refs:*  
  - Gregg, Ch. 2.3.1 (pp. 24–25)  
  - Ch. 2.8 (p. 75)  
  - Ch. 2.9–2.10 (pp. 77–78+)
    
### 2.7 Tenancy & quotas
Split EPS by `{region, tenant}`, enforce quotas **edge → broker → ingesters → queriers**, return **429 + Retry-After** on exceed, and watch **cardinality** to cut off offenders. This isolates noisy neighbors and keeps capacity predictable; one team’s spike can’t blow everyone’s SLOs.

- **Rationalization & enforcement:** apply **priorities** (shares/weights) and **limits** (bandwidth/ceilings) per resource; degrade non-critical classes first.  
  *Refs (Brendan Gregg, Systems Performance 2e — page-accurate):*  
  - Multi-tenant contention & resource controls: Ch. 11, §11.3 “OS Virtualization”, pp. 613–617  
  - CPU: CFS shares (priority), CFS bandwidth/cpusets (limits), pp. 614–615  
  - Memory: soft+hard limits, `memory.pressure_level` notifiers, pp. 616–617  
  - Disk I/O: `blkio.weight` + `blkio.throttle.*` (BPS/IOPS), p. 617  
  - Network I/O: `net_prio`/`net_cls` + qdiscs (fq/fq_codel/tbf), BPF at tc/cgroup, p. 617 and Ch. 10 pp. 520–522, 571–573

- **Cardinality controls:** per-tenant **series & samples/s** limits; dashboards for series growth; CI lint to block forbidden labels.  
  *Why:* prevent TSDB blow-ups; complements OS-level fairness.
  
### 2.8 Security & Compliance (Essentials)

**Assumptions (explicit, testable)**  
- **Data classes**  
  - *Metrics:* low-cardinality ops data; **no PII** (enforced at edge).  
  - *Logs:* may contain sensitive fields; **tokenize/redact at collection**.  
- **Tenancy:** multi-team, multi-title ⇒ per-tenant isolation across ingest, query, storage.  
- **Trust boundaries:** clients → edge collectors → stream → TSDB / log stores; some servers at third parties (treat as untrusted edges).  
- **Crypto posture:** TLS 1.2+ in transit; AES-GCM at rest; keys in **AWS KMS**; short-lived certs/tokens.  
- **Compliance target:** SOC 2 / ISO 27001 “lite” (access control, auditability, retention/deletion, incident response).  
- **Ops constraints:** zero-trust-ish defaults; least privilege; automated rotation; immutable artifacts (images/config).

**Design philosophy (why + how)**  
- **Privacy by design:** keep PII out of metrics by schema; enforce with CI lint + runtime reject. Treat logs as sensitive; **tokenize at edge** before transport.  
- **Defense in depth:** isolate by tenant + region (logical tenancy + physical separation such as **S3 prefixes/buckets**; per-env **KMS** keys).  
- **Fail-safe defaults:** drop unknown labels/fields; deny on missing auth; short credential lifetimes.  
- **Provable controls:** violations alert; admin/API actions are tamper-evident.  
- **Operational simplicity:** prefer **IAM/KMS**-managed primitives and **signed, immutable images** to reduce drift.

**Day-1 controls (required)**

*Data shaping & collection*  
- Metrics **label allowlist (repo-enforced):** allow `{region, az, cluster, shard_id, instance_type, build_id, queue, asn_bucket}`; block `{player_id, raw_ip, email, request_id, free-text}`.  
- Edge tokenization for logs: redact emails/IPs; hash IDs with per-env salt; **drop on parser failure**.  
- Per-tenant quotas at collector/stream (EPS, bytes/s) → **429 + Retry-After** on exceed.

*AuthN / AuthZ*  
- **mTLS** for agent↔collector↔broker↔store; short-lived X.509 (**SPIFFE/SPIRE** or equivalent).  
  - SPIFFE/SPIRE: <https://spiffe.io/>  
- Per-tenant scopes (write/read) at gateway & store; separate creds per tenant.  
- Least-privilege **IAM**: write-only to ingest; scoped read via dashboards/service accounts; no blanket admin.

*Encryption*  
- **In transit:** TLS 1.2+; HSTS on UIs.  
- **At rest:** **KMS**-encrypted TSDB blocks, indices, S3 objects; distinct keys per environment (per-tenant keys only if required).  
  - AWS KMS: <https://docs.aws.amazon.com/kms/latest/developerguide/overview.html>

*Isolation*  
- **Network:** collectors/brokers/stores in private subnets; minimal egress; **WAF** on public UIs; tight security groups.  
- **Runtime:** run agents/collectors non-root, read-only FS; apply **seccomp/AppArmor** profiles.

*Integrity & supply chain*  
- **Immutable images** (Golden AMIs/OCI) with **SBOM**; sign artifacts; deploy only signed images; **IMDSv2-only**; SSH disabled (use **SSM Session Manager**).  
  - CIS Benchmarks: <https://www.cisecurity.org/cis-benchmarks/>  
  - AWS SSM Session Manager: <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html>

*Governance*  
- **Retention & deletion:** metrics **14 d hot / 90 d warm / 13 mo cold**; logs **7 d / 30 d / 365 d**. Keep a documented deletion workflow with evidence (S3 inventory deltas).  
- **Audit logging:** admin/API actions, auth successes/failures, policy rejects → ship to **S3 object-lock (WORM)**.  
- **Secrets:** no secrets in images; **Parameter Store/Secrets Manager**; auto-rotate ≤90 d with near-expiry alerts.

*Minimal framework alignment*  
- **NIST 800-53 / ISO 27001 mapping (essentials):**  
  - Access Control / Identification & Auth: **IAM**, per-tenant scopes, **mTLS**.  
  - System & Communications Protection: **TLS** everywhere, **KMS** at rest, private networking.  
  - Audit & Accountability: **CloudTrail** / audit logs to **WORM S3**.  
  - Configuration Mgmt: **IaC** + **AWS Config**/conformance checks; **immutable images**.  
  - AWS Security Hub standards: <https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-standards.html>  

- **BC residency (FOIPPA) stance:** default telemetry to **Canada** regions; document any cross-border replication and apply compensating controls (KMS, tokenization, access logs).  
  - FOIPPA overview: <https://www2.gov.bc.ca/gov/content/governments/services-for-government/information-management-technology/privacy>  

**“Prove it” (lightweight verification)**  
- PII guardrails test: CI injects bad labels/fields → build fails; staging agents send PII → edge drops + alert.  
- Crypto SLOs: 100% TLS; no certs <7 days to expiry without alert.  
- Access reviews: quarterly principal/permission review; anomaly detection on per-tenant query volumes.  
- Deletion drills: quarterly verify hot→warm→cold→expire; show S3 inventory diffs.

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

## 3 Architecture (AWS)

> _Add diagram(s) here._

### 3.1 Components & AWS Services
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

### 3.2 Data Flow (high level)
1. Agents emit counters + histograms every 10 s (5 s during incidents).  
2. Metrics: ADOT → Kinesis/MSK → AMP/Mimir.  
3. Logs: Fluent Bit → Firehose → OpenSearch (hot) & S3 (raw/Parquet).  
4. Grafana queries AMP/Mimir/OpenSearch; alerts route via CloudWatch/PD/Slack.

---

## 4 Capacity & Storage Planning

### 4.1 Ingest & Storage
- **EPS baseline:** ~150k samples/s (**≥200k/s target**).  
- **Bytes/sample (plan):** ~15–20 B amortized.  
- **Daily hot metrics (global):** ~200–260 GB/day (**budget: ~500 GB/day/region** incl. index/replicas).

### 4.2 Retention (fill with final choices)
- **Metrics:** Hot 10s **7–14d** → Warm 1–5m **30–90d (up to 180d)** → Cold 5m/1h **~13mo (S3)**.  
- **Logs:** **7d** hot / **30d** warm / **365d** cold (S3).

### 4.3 S3 Lifecycle (concept)
- Metrics blocks: **30d → IA**; **180d → Glacier**; **expire 400d**.  
- Logs: **30d → IA**; **365d → Glacier**; **expire 730d**.

---

## 5. SLOs, Alerts & Dashboards

### 5.1 SLOs
- **Freshness:** write→read **p99 ≤ 10s**.  
- **Query latency:** **p95 ≤ 2s (≤12h)**, **p99 ≤ 10s (7–30d)**.  
- **Ingest TTFB:** **p99 ≤ 250–350ms** @ 1×–3×.

### 5.2 Alert Policy (examples to instantiate)
- Burn rate for player‑facing SLIs.  
- Freshness breach (>10s p99).  
- Query p95/p99 regressions.  
- Cardinality growth / limits approaching.  
- Compactor lag / object‑store errors.

### 5.3 Dashboard Standards (add links/screens later)
- Golden Signals per service.  
- Gameplay SLIs.  
- Infra/Network health.  
- Cost & storage (bytes/day by tier, cache hit, read amplification).

---

## 6. Tenancy, Quotas & Fairness

- **Tenant model:** (teams/titles listed).  
- **Per‑tenant quotas:** EPS, samples/s, max series, query limits.  
- **Enforcement points:** edge → stream → ingesters → query‑frontend.  
- **Overage behavior:** HTTP **429 + Retry‑After**; shed non‑critical classes first.  
- **Cardinality guard:** dashboards + kill switches; CI lints schema.  
- **OS fairness controls:** CPU shares/bandwidth; memory soft/hard; blkio weights/throttles; qdiscs/BPF shaping.

---

## 7. Security & Compliance (Essentials)

### 7.1 Principles (recap)
- No PII in metrics; tokenize logs at collection; mTLS; KMS; least privilege; immutable & signed images; audit logs to S3 WORM.

### 7.2 Day-1 Checklist
- [ ] Label allowlist & edge reject in exporters/collectors  
- [ ] mTLS chain (agents↔collectors↔brokers↔stores), short‑lived certs  
- [ ] Per‑tenant scopes & RBAC in gateway/store  
- [ ] KMS keys per environment (per‑tenant optional)  
- [ ] Private subnets, strict SGs, WAF on public UIs  
- [ ] Secrets in SSM/Secrets Manager; rotation ≤90d  
- [ ] Retention & deletion process documented  
- [ ] Residency stance and replication policy documented

---

## 8. Build & Implementation Plan

### 8.1 Environments
- **Dev / Staging / Prod:** parity, canary tenants, synthetic load toggles.

### 8.2 Delivery Milestones (fill dates)
1. Architecture ready (docs/diagrams/limits) — **TBD**  
2. Foundations (VPC, EKS or AMP, S3, IAM, KMS) — **TBD**  
3. Pipelines up (Kinesis/Firehose/OpenSearch) — **TBD**  
4. Agents baked (exporters, ADOT, Fluent Bit) — **TBD**  
5. Dashboards & alerts (MVP) — **TBD**  
6. Capacity tests (T0–T8) — **TBD**  
7. Security sign‑off — **TBD**  
8. Go‑live — **TBD**

### 8.3 RACI (example)
| Task | Eng | SRE | Sec | PM | Owner |
|---|---:|---:|---:|---:|---:|
| Network / VPC / SGs | R | A | C | I |  |
| AMP/Mimir setup | R | A | C | I |  |
| Logs pipeline (OS/S3) | R | A | C | I |  |
| Dashboards/Alerts | R | A | C | I |  |
| Capacity tests | A | R | C | I |  |
| Security controls | C | R | A | I |  |

---

## 9. Operations

### 9.1 Runbooks (link/add later)
- Freshness breach  
- Query slowness  
- Cardinality spike  
- AZ/broker failure  
- Data loss suspected

### 9.2 SRE On-call
- **Coverage model:** _(fill)_  
- **Escalation path:** _(fill)_  
- **Status comms:** Slack / Email / StatusPage

### 9.3 Change Management
- IaC + PR reviews; blue/green or canary for agents & pipelines; rollback criteria.

---

## 10. Capacity Tests & Readiness Gates

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

## 11. Cost & FinOps (initial)

- **Major cost drivers:** S3 storage & requests, query/read ops, OpenSearch hot nodes, Kinesis/MSK throughput.  
- **Levers:** downsampling, lifecycle policies, cache hit ratio, query limits, log sampling, cold formats (Parquet/ORC).  

**Monthly estimate placeholders (fill post‑POC):**  
- Metrics hot/warm: **$ ___**  
- S3 storage + requests: **$ ___**  
- OpenSearch hot/warm/cold: **$ ___**  
- Kinesis/MSK: **$ ___**  
- Grafana/AMP/EKS: **$ ___**

---

## 12. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---:|---|
| Cardinality explosion | Query/ingest outage | M | CI lint; per‑tenant limits; kill switch |
| Compactor lag | Slow historical queries | M | Size compactor; monitor; S3 health alarms |
| Cost overrun | Budget breach | M | Downsample; lifecycle; query controls |
| Residency constraints | Non‑compliance | L/M | Canada‑first, disable cross‑Region replication, non‑MR KMS |
| 3rd‑party infra gaps | Blind spots | M | Edge QoE metrics; external probes; contracts |

---

## 13. Open Questions
- Regions final?  
- AMP vs Mimir decision?  
- Tracing required at day‑1?  
- Residency/contractual constraints for specific tenants?  
- On‑call coverage and SLAs?

---

## 14. Appendices
- **A.** Architecture diagrams (current, target)  
- **B.** Label schema & lint rules  
- **C.** Recording rules catalog  
- **D.** Alert catalog (burn rates, freshness, query)  
- **E.** S3 lifecycle policies (metrics/logs)  
- **F.** Runbooks (R1–R4)  
- **G.** Test reports (T0–T7)  
- **H.** Security control matrix (NIST/ISO mapping)

---

## 15. Improvements Adornment

### 15.1 Immutable Golden Images (deterministic rollouts)
- Pre‑baked OS images with exporters/ADOT/Fluent Bit, SBOMs, signatures, read‑only FS, cloud‑init last‑mile.  
- Health gate `/ready?exporters=ok&wg=ok&xdp=ok`; start‑time SLO: **p95 power→metrics < 60s**.  
- Rollouts via ASG instance‑refresh; fast rollback by image version.

### 15.2 Cilium + Hubble & eBPF summaries
- L3–L7 flow visibility; eBPF histograms (runqlat, tcpretrans, biolatency) **≤3% CPU** budget; XDP drop/shape junk traffic early.  
- Dashboards: overlay_xdp_drops_total, overlay_peer_rtt_ms, overlay_peer_loss_ppm.

### 15.3 Firecracker microVM sidecars (agent isolation)
- ADOT/Fluent Bit/exporters inside microVMs; dedicate **0.5–1 vCPU** & RAM slice; independent lifecycle; near‑container boot times **(<5s P95)**.

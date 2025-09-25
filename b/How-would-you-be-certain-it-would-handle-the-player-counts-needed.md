# Capacity Validation & Readiness Gates — Can it handle the player counts?

This document turns the design’s SLOs and assumptions into **measurable acceptance tests** so we can ship on evidence, not hope. It defines **what to test, how to test it, pass/fail thresholds, tooling, and artifacts** to retain for audit.

---

## TL;DR — What we prove
- **Sustained ingest** at or above the modeled load (≥200k samples/sec global; ≈50k/sec per region) **for 2–6 hours** with **zero loss** and **freshness p99 ≤ 10s**.
- **Burst resilience** at **1× / 3× / 5× baseline** with **orderly backpressure** and backlog drain **< 30 min**.
- **Operator UX**: dashboard **p95 ≤ 2s** (≤12h ranges) and **p99 ≤ 10s** (7–30d ranges), **cache hit ≥ 80%**.
- **Fault tolerance**: **AZ loss or broker failure** causes **no data loss** and **freshness recovers < 2 min**.
- **Replay durability** after a 10–20 min ingest pause, **no out-of-order explosions**.
- **Cardinality controls** block forbidden labels and prevent WAL/index blowups.
- **Autoscaling follows outcomes** (freshness/query p95/cache-hit), not CPU-only, and **stays within cost guardrails**.

---

## Test Matrix (T0–T8)

> Run in **staging** first with prod-like data shapes and then in **prod under a canary tenant**. Use the same histogram buckets and label sets as production.

| ID | Name | Why | Setup | Pass / Fail |
|---:|---|---|---|---|
| **T0** | Env Parity & Canary | Prove config/image parity before heavy tests | Mirror **1%** real traffic to a **canary tenant** | **Pass:** All parity dashboards green; **0 policy rejects**; divergence < **1%**. **Fail:** Any reject or >1% divergence. |
| **T1** | Ingest Soak (≥1.3×) | Verify write path capacity & durability | Synthetic producers push **≥200k samples/sec** global for **2–6h** | **Pass:** **0 loss**; write→read **p95 < 30s**, global **p99 ≤ 10s**; WAL replay < **5 min** on restart. **Fail:** drops/WAL stalls/SLO breach. |
| **T2** | Burst 1×/3×/5× | Patch/match-start resilience | 15-min bursts to **1× / 3× / 5×** baseline with realistic label churn | **Pass:** Backpressure engages; non-critical classes shed first; **backlog drains < 30 min**; **no core SLI loss**. **Fail:** core SLI loss or backlog plateau. |
| **T3** | Query Load | Operator UX under pressure | ~**200 concurrent viewers** hit top dashboards; mix of ranges (≤12h and 7–30d) | **Pass:** **p95 ≤ 2s** (≤12h) and **p99 ≤ 10s** (7–30d); **cache hit ≥ 80%**. **Fail:** cache thrash/misses. |
| **T4** | Chaos (AZ/Broker loss) | Fault-tolerance & recovery | Kill **one AZ worth of ingesters/queriers** or **one broker node** | **Pass:** **0 data loss** (WAL + replication); **freshness recovers < 2 min**. **Fail:** gaps or prolonged staleness. |
| **T5** | Backpressure & Replay | Durability & orderly catch-up | Pause **stream partitions** for **10–20 min**, then resume | **Pass:** Agents/collectors buffer; priority shed OK; **clean catch-up**; **no out-of-order** spikes. **Fail:** DLQ growth or stuck lag. |
| **T6** | Data Completeness | Are all expected series present? | Tenant emits **known count of series (±1%)** per shard | **Pass:** **≥99.9%** present per 5-min window. **Fail:** sustained missing-series. |
| **T7** | Cardinality Guard | Prevent WAL/index blow-ups | Introduce **forbidden label** in staging | **Pass:** **Edge rejects + alert ≤ 1 min**; store sees **0** new series. **Fail:** any acceptance. |
| **T8** | Cost/SLO Guardrails | Scale to outcomes, within budget | Scale during **T1–T3** | **Pass:** Autoscaling driven by **freshness / query p95 / cache hit** (not CPU-only); **object-store ops/query within budget**; SLOs stay green. **Fail:** SLO breach during scale. |

**Hard ship gates:** **T1, T3, T4, T5**.  
**Soft ship gates:** **T2, T6, T7, T8** (fix-forward OK with mitigations & live alerts).

---

## Load Shapes & Targets

- **Baseline EPS**: ~**150k samples/sec** global (derived from **5,000 hosts × 300 series ÷ 10s**).  
  **Target test EPS**: **≥200k/sec** global (30% headroom), ~**50k/sec/region**.
- **Metrics shape**: **counters + exponential histograms only**, strict label allowlist `{region, az, cluster, shard_id, instance_type, build_id, queue, asn_bucket}`.
- **Logs**: steady flow to validate Firehose→OpenSearch/S3 backpressure ordering.

---

## Tooling & Fixtures

- **Synthetic Metrics Producers**  
  - Emit **counters** and **exponential histograms** with **realistic label sets**.  
  - Configurable **EPS**, **burst multipliers**, **jitter**, **drop/error modes**.  
  - Export **sent/ack counters** to compute true loss.
- **Dashboard Replay Loader**  
  - Replays the top **N dashboards** with a **range mix**: 60% ≤6h, 30% ≤12h, 10% 7–30d.  
  - Measures **client-side render p95/p99** and server **request_duration_seconds**.
- **Chaos Injector**  
  - AZ cordon/drain for ingesters/queriers (EKS) or stop EC2/broker nodes.  
  - Stream partition pause/resume (Kinesis/MSK) with controlled duration.
- **Probes (Outside-In)**  
  - Tiny EC2/Lambda posting a synthetic series and immediately querying it to compute **ingest_to_query_age_seconds**.
- **Autoscale Orchestrator**  
  - Scales gateway/ingester/query tiers based on **freshness/query p95/cache-hit**; records decisions and effects.

> Implementation note: you can host producers and loaders either on **EKS jobs** or **ASG** backed EC2 nodes for simpler quota control.

---

## Oracles & Key Metrics

- **Freshness**: `ingest_to_query_age_seconds` (**histogram**) — SLO **p99 ≤ 10s**.  
- **Ingest acceptance**: gateway/ingester **accept rate**, WAL fsync and queue latencies.  
- **Loss**: producer-side `samples_sent_total` vs store-side `samples_indexed_total`.  
- **Query UX**: Grafana panel timers + AMP/Mimir `request_duration_seconds`.  
- **Cache health**: **frontend/store-gateway cache hit %** (target ≥ 80%).  
- **Compaction**: compactor **backlog**, block merge sizes, **bucket-index** sync time.  
- **Cost signals**: S3 **GET/PUT per query**, read amplification, OpenSearch **hot shard pressure**.

---

## Test Harness — Example Shapes (pseudocode)

```yaml
# producer.yaml (helm values or env vars)
eps: 50000                 # per region
series_per_host: 300
host_count: 1700           # per region
emit_interval: 10s
burst_pattern:
  - {multiplier: 3, duration: 15m, jitter: true}
  - {multiplier: 5, duration: 15m, jitter: true}
labels_allowlist:
  - region
  - az
  - cluster
  - shard_id
  - instance_type
  - build_id
  - queue
  - asn_bucket
fail_modes:
  - {type: network, drop_ppm: 100}
  - {type: latency, p95_additional_ms: 200}
```

```bash
# Query loader: 200 viewers mix
replay-dashboards \
  --grafana-url $GRAFANA_URL \
  --concurrency 200 \
  --range-mix "60:6h,30:12h,10:30d" \
  --slo-p95 2s --slo-p99 10s \
  --out results.ndjson
```

---

## Run Order & Timebox

1. **T0** Parity/Canary (15–30 min) → unblock heavy tests.  
2. **T1** Ingest Soak (≥2h, ideally 6h) → exercise compaction/GC cycles.  
3. **T2** Bursts (45 min) → confirm backpressure & drain.  
4. **T3** Query Load (30–60 min) in parallel during T1/T2 windows.  
5. **T4** Chaos (15–30 min) → after steady state achieved.  
6. **T5** Replay (30–45 min).  
7. **T6–T8** Guards (≤30 min total).

> Collect artifacts continuously; don’t extend tests—**rerun** rather than chase tail effects.

---

## Artifacts to Retain (per run)

- **Dashboards screenshots/PNGs**: freshness, accept rate, compactor lag, cache hit, query durations.
- **Raw logs/metrics**: producer **sent vs ack** deltas; edge/gateway rejections (429s, label-policy), DLQ if any.
- **Config snapshots**: limits (series/sample/query), autoscaling policies, compactor settings, retention & lifecycle configs.
- **Chaos runbooks & timelines**: who/what/when, recovery curves.
- **Cost sample**: S3 ops/query, OpenSearch hot shard stats, bytes/day added per tier.

Store under `runs/YYYYMMDD_region/` with a short **README.md** per run.

---

## Pass/Fail & Ship Criteria

- **SHIP** only if **T1, T3, T4, T5** pass.  
- **Fix-forward** allowed for **T2, T6, T7, T8** **iff** mitigations are documented, alerts are live, and risk is agreed by SRE + product.

---

## Automation Hooks

- **Terraform outputs** export AMP/AMG/OpenSearch endpoints and regional quotas to the test harness.  
- **GitHub Actions** job `capacity-suite.yml` runs T0–T8 nightly in **staging** and on-demand in **prod canary**.  
- **Results** posted to Slack/PagerDuty and archived in S3 with object-lock.

---

## FAQ

- **Why histogram-only at the edge?**  
  Accurate p95/p99 without per-event explosion keeps series bounded and costs predictable.

- **Why streams in front of the TSDB?**  
  Kinesis/MSK absorbs bursts and enables replay so producers aren’t coupled to store hiccups.

- **Why scale on freshness/query p95/cache-hit?**  
  These are **user-visible outcomes**; CPU alone is an indirect and often misleading signal.

---

## Appendix — Quick SLO Reference

- **Freshness** (write→read): **p99 ≤ 10s**.  
- **Ingest TTFB**: **p99 ≤ 250–350ms** @ 1×–3×.  
- **Query latency**: **p95 ≤ 2s** (≤12h), **p99 ≤ 10s** (7–30d).  
- **Completeness**: **≥99.9%** of expected series present per 5-min window.

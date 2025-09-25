## Don’t flood it — Emit summaries only
-  What to emit: counters + (exponential) histograms; no per-event time series.
-  Exporter budget per host: ≤ 300 active series; CPU overhead ≤ 2% at 10s; ≤ 3% at 5s (incident mode).
-  OTel/ADOT (agent) hint:
```yaml
processors:
  batch: { timeout: 5s, send_batch_size: 2000, send_batch_max_size: 5000 }
  transform:  # drop per-event metrics if they slip in
    metric_statements:
      - context: metric
        statements:
          - delete_metric(name == "request_duration_seconds") # if this is a summary
exporters:
  prometheusremotewrite:
    endpoint: ${GATEWAY_URL}
    tls: { insecure: false }
    external_labels: { region: ${REGION}, build_id: ${BUILD_ID} }
```
- Server histograms: prefer OTel exponential or Prom histogram with ~12–16 buckets per decade to keep payloads small and quantiles accurate.

##  Bound cardinality — Schema + enforcement
-  Allowlist only: {region, az, cluster, shard_id, instance_type, build_id, queue, asn_bucket}.
-  Edge rejects: drop samples containing {player_id, raw_ip, email, request_id, free_text}.
-  CI lint (example):
```yaml
rules:
  - forbid_labels: [player_id, ip, email, request_id]
  - allow_labels:  [region, az, cluster, shard_id, instance_type, build_id, queue, asn_bucket]
  - max_series_per_host: 300
```
Gateway enforcement (ADOT/Mimir RW-gateway):
-  Per-tenant limits: max_series, samples_per_second, max_label_names, max_label_value_length.
-  On exceed: return 429 with Retry-After; emit tenant_over_limit_total.

## Decouple producers — Durable stream first
- Why: absorb bursts, replay safely, and fan-out to multiple sinks (metrics/logs/archives) without coupling edge to TSDB.
- Kinesis (typical per-region starting point):
  -  Shards: derive from peak PUTs & payload size; start 24–48 shards (scale by metrics QPS).
  -  Records: bundle remote_write frames to <= 1 MB; 1,000 records/s/shard.
  -  Retry/Backoff: exponential; max 5–10 min.
- MSK (Kafka) alternative:
  - Partitions: target > 2× ingest concurrency; min ISR=2; acks=all.
  - Retention: short (2–6 h) for metrics; logs per ILM.
- Firehose (logs): logs→OpenSearch (hot) & S3 (raw/Parquet) with on-failure S3 bucket.

## Tiered retention — Fast hot, cheap long
- Hot metrics (AMP/Mimir): 10s resolution, 14 days.
- Warm metrics: 1–5m downsample, 180+ days (still queryable).
- Cold metrics: 5m/1h rollups to S3 (Parquet/ORC), ~13 months.
- Logs: 3–7d hot (OpenSearch) → 30d warm → 365d+ cold (S3).
Recording rules (examples):
```yaml
groups:
- name: gameplay_rollups
  interval: 30s
  rules:
  - record: :gameplay:tick_p95
    expr: histogram_quantile(0.95, sum by (le,region,queue) (rate(gameplay_tick_time_seconds_bucket[5m])))
  - record: :gameplay:ack_p99
    expr: histogram_quantile(0.99, sum by (le,region,queue) (rate(action_ack_latency_seconds_bucket[5m])))
```
- Mimir/AMP knobs: enable query/result cache, store-gateway cache, size compactor for large merged blocks (fewer indexes to scan).

## SLO-driven backpressure & autoscaling — Outcomes, not CPU
- Platform SLOs:
   - Freshness (write→read) p99 ≤ 10s
   - Query p95 ≤ 2s (≤12h), p99 ≤ 10s (7–30d)
   -  Ingest TTFB p99 ≤ 250–350ms

- Autoscale signals:
   - Ingest: freshness p95/p99, WAL append latency, samples/s; not CPU alone.
   - Query: query duration p95, cache hit ratio, queued requests.

- Shed order (protect gameplay SLIs):
    - Verbose logs (reduce/suppress)
    - Low-priority tenants (weight-based throttling)
    - Expensive queries (kill/slow with budgets)
    - Ingest rate (temporary 429 with Retry-After)
- Gateway policy (pseudocode):
```yaml
tenants:
  default:
    samples_rate_limit: 20_000/s
    max_series: 2_000_000
    priority: 100
  lowprio:
    samples_rate_limit: 5_000/s
    priority: 10
overload:
  freshness_threshold_p99: 10s
  actions:
    - reduce_log_sampling: 50%
    - throttle_tenants: ["lowprio"]
    - enable_slow_query_killer: true
```

## Security & tenancy — Make it fast and safe
-  mTLS everywhere: agents↔gateway↔broker↔store (short-lived certs; SPIFFE/SPIRE optional).
-  PII-free metrics: enforced by edge schema and gateway relabel/reject.
-  Per-tenant isolation: write tokens & query RBAC; per-tenant KMS keys only if required.
-  Pivate data paths: VPC endpoints for S3/AMP/AMG/Kinesis/OpenSearch; UIs behind WAF; IMDSv2-only; SSH disabled (SSM Session Manager).

## Cost controls that preserve performance
-  Caches: keep result cache hit ≥ 80% on hot boards; alert if it drops.
-  Object-store ops/query: alarm on spikes; use bigger merged blocks via compactor to cut reads.
-  Downsampling: push long-range queries to Athena on S3 (Parquet).
-  Dashboard budgets: cap range selectors, forbid unbounded fan-outs, precompute rollups used on home boards.

## Prove it — Acceptance gates (quick)
-  T1 Soak: ≥ 1.3× baseline (≥200k samples/s global) for 2–6h → 0 loss, freshness p95 < 30s.
-  T2 Bursts: 1×/3×/5× for 15m → backlog drains < 30m, SLIs intact.
-  T3 Query load: ~200 viewers → p95 ≤ 2s (≤12h), p99 ≤ 10s (7–30d), cache ≥ 80%.
-  T4 Chaos: kill an AZ of ingesters/queriers → 0 loss, freshness recovers < 2m.
-  T5 Replay: pause stream 10–20m → clean catch-up, no OOO explosions.

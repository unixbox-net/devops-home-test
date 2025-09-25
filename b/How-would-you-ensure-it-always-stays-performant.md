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

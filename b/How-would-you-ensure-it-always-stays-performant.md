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


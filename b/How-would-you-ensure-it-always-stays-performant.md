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

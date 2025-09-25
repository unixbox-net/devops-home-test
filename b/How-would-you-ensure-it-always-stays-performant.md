### How it stays performant (by construction)
- Don’t flood it. Servers emit summaries only (counters + histograms). No per‑event time series.
- Bound cardinality. Strict label allowlist and ~300 series/server budget enforced in CI and at the edge; rollouts gated on budget.
- Decouple producers. Telemetry first lands in a stream (Kinesis/MSK) to absorb bursts, enable replay, and fan‑out.
- Tiered retention. Hot 10s for ~14 d, warm 1–5 m for 180+ d, cold Parquet/ORC on S3 for audits/backfills. Recording rules precompute p95/p99 and rollups.
- SLO‑driven backpressure. Quotas at edge→broker→ingesters→queriers; shed non‑critical classes first (e.g., verbose logs).
- Security & tenancy. Per‑team tenants/quotas; TLS/KMS; PII‑free metrics.

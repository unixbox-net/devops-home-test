## Gameplay SLIs (player-visible health)
Shape: counters + (exponential) histograms; strict label allowlist.
Examples (Prometheus-style):
-  gameplay_tick_time_seconds_bucket{region,az,cluster,shard_id,build_id,instance_type} — server tick duration.
-  action_ack_latency_seconds_bucket{region,queue,build_id} — client action → server ack.
-  match_admissions_total{region,queue,build_id,outcome="admitted|rejected|timeout"} — admission control results.
-  errors_total{region,category="rpc|asset|auth|db"} — gameplay-visible errors.
-  voice_mos_bucket{region,az,queue} — estimated voice MOS histogram.
-  instance_density{region,shard_id} — players per instance.

Labels allowed: region, az, cluster, shard_id, instance_type, build_id, queue, asn_bucket.
PII forbidden: no player_id, ip, email, request_id, or free-text.
Retention: hot 10s for 14d; warm 1–5m for 180d; cold rollups (5m/1h) to ~13mo.
Why: Directly map to what players feel (rubber-banding, lag, failed joins) with bounded cardinality.

## Infrastructure & Network SLIs (root-cause signals)
Shape: counters/gauges + histograms; low cardinality.
Host/Process (node & runtime):
-  node_cpu_seconds_total{mode} / node_memory_Active_bytes / process_cpu_seconds_total — headroom and contention.
-  disk_io_latency_seconds_bucket{device} — I/O path health (esp. on ingesters/queriers).
-  go_gc_duration_seconds_bucket (for Go services), process_open_fds — GC/FD saturation.

Network (kernel & overlay):
-  tcp_retransmissions_total{region,az,node} — congestion/packet loss indicator.
-  net_rx_drops_total{iface} — driver/IRQ pressure.
-  overlay_rtt_ms_bucket{asn_bucket} / overlay_jitter_ms_bucket{asn_bucket} / overlay_loss_ppm{asn_bucket} — edge QoE by ASN.
-  eBPF/XDP overlay_xdp_drops_total{reason}, runqlat_ms_bucket{node} — early drop and scheduler latency.

Retention: similar to gameplay SLIs; long-range rollups stored in S3/Parquet.
Why: Explain why gameplay SLOs breach (CPU, disk, NIC, path loss).

## Ops/Business Overlays (context, not identity)
Shape: counters/gauges; tiny label set.
Examples:
-  ccu{region} — concurrent users by region.
-  rollout_progress_ratio{build_id,region} — phased deploy progress.
-  error_budget_burn_rate{service} — SLO burn.
-  ingest_qps{tenant,region} / samples_accepted_total{tenant} — pipeline throughput.
-  query_cache_hit_ratio{tier} / object_store_ops_per_query{tier} — cost/perf health.

Retention: hot for 14d; downsampled to S3 for trend analysis.
Why: Adds decision context without polluting metrics with PII or high-cardinality labels.

## Logs (separate store; tokenized)
Shape: JSON logs; hot search + warm/cold archive.
Pipelines: Fluent Bit → Firehose → OpenSearch (hot 3–7d) & S3 (raw/Parquet).
Schemas (examples):
-  service, level, event, build_id, region, az, tenant, trace_id?, span_id?, hash_user (tokenized).
-  Drop/Redact at edge: emails/IPs; hash IDs with per-env salt.
Why: Deep diagnostics & audit without polluting metrics cardinality.

## Traces
Shape: spans with service/operation/timing; sampled.
Backends: AWS X-Ray (managed) or Grafana Tempo (EKS + S3).
Usage: Join with logs via trace_id; correlate with gameplay latency histograms.
Why: Swift code-path attribution for the top N incident flows.

## Platform Health & SLO Telemetry (meta-observability)
Must-haves:
-  ingest_to_query_age_seconds_bucket{region,tier} — freshness (write→read age) shown on every dashboard.
-  gateway_first_byte_seconds_bucket{tenant} — ingest TTFB (TLS/queueing issues).
-  query_frontend_request_duration_seconds_bucket{range=tier} — query p95/p99 by range (≤12h, 7–30d).
-  compactor_backlog_blocks{cluster} / store_gateway_cache_hit_ratio — storage/query health.
-  series_active{tenant} / samples_rate{tenant} — cardinality and throughput guardrails.
Why: Ensure the observability plane itself meets SLOs and scales to user-visible outcomes.

## Governance Metadata (tags & policy)
Attach tags to all resources/series where applicable (and enforce via CI/lints):
Environment, Region, Tenant, Service, DataClass (Metrics|Logs|Traces), RetentionTier (Hot|Warm|Cold), Owner, CostCenter, Compliance (PII-Free|Sensitive), BuildID.
Why: Cost allocation, policy enforcement (ILM/Lifecycle), delete-by-policy, and quick forensics.

## Retention (quick reference)
Metrics: 10s for 14d (hot) → 1–5m for 180d (warm) → 5m/1h to ~13mo (cold on S3/Parquet).
Logs: 3–7d hot in OpenSearch → 30d warm → 365d+ cold in S3 (tokenized).
Traces: sampling + 7–14d short TTL (X-Ray/Tempo), optional span summaries to S3.

## Cardinality budget & safety rails
Budget: ~300 active series per game server; strict label allowlist.
Enforcement: CI lints, gateway relabel/reject, per-tenant series & samples/s limits, 429 + Retry-After on overage.
Dashboards: “New series” trend, top label keys/values, and per-tenant growth.

## What data the cluster holds
- Gameplay SLIs: tick time histograms, action→ack latency histograms, instance density, queue/admission counters, error rates, voice MOS.
- Infra & network SLIs: host CPU/mem/GC, disk I/O latency, NIC utilization/retransmits, SYN backlog; edge RTT/jitter/loss histograms bucketed by ASN.
- Ops/business overlays: CCU, rollout %, error‑budget burn, ingest QPS, cache hit. (Player‑level details stay in logs; metrics remain PII‑free.)

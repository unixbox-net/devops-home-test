# JP Evening Latency — All‑in‑One Case Runbook & Troubleshooting Methodology
_A single, self‑contained Markdown that **answers the specific case questions** and documents **how I troubleshoot**. It includes the **W’s intake**, **Fishbone (Ishikawa)** model, userland commands, custom diagnostic scripts, and **in‑kernel** instrumentation (eBPF/DTrace). Built for copy‑paste execution and white‑glove collaboration with providers._

---

## Table of Contents
- [0) Ethos & Models](#0-ethos--models)
- [1) The W’s — Question‑First Intake (Full Checklist)](#1-the-ws--questionfirst-intake-full-checklist)
- [2) Access & Environment Discovery](#2-access--environment-discovery)
- [3) The Case (C) — Direct Answers](#3-the-case-c--direct-answers)
  - [3.1 How I confirm the issue & collaborate with the provider](#31-how-i-confirm-the-issue--collaborate-with-the-provider)
  - [3.2 Extra info (i): Third‑party host with weak metrics — how I get signal](#32-extra-info-i-thirdparty-host-with-weak-metrics--how-i-get-signal)
  - [3.3 Extra info (ii): Mix of cloud & bare metal — W’s for each + L2→L7 proof](#33-extra-info-ii-mix-of-cloud--bare-metal--ws-for-each--l2l7-proof)
  - [3.4 Data & metrics required to confirm the issue](#34-data--metrics-required-to-confirm-the-issue)
  - [3.5 Tooling I need in place (incl. custom craftables)](#35-tooling-i-need-in-place-incl-custom-craftables)
  - [3.6 Debug steps — Fishbone (Ishikawa) applied to latency](#36-debug-steps--fishbone-ishikawa-applied-to-latency)
  - [3.7 Working with the game‑server provider — white‑glove playbook](#37-working-with-the-gameserver-provider--whiteglove-playbook)
- [4) End‑to‑End Procedure (Line‑by‑Line Execution)](#4-endtoend-procedure-linebyline-execution)
- [5) Examples: Commands, Scripts, and eBPF/DTrace](#5-examples-commands-scripts-and-ebpfdtrace)
- [6) Provider Command Pack & Escalation Template](#6-provider-command-pack--escalation-template)
- [7) Acceptance Criteria (Definition of Done)](#7-acceptance-criteria-definition-of-done)
- [8) Appendices (Evidence Log, PromQL, Tool Links)](#8-appendices-evidence-log-promql-tool-links)

---

## 0) Ethos & Models
**Ethos:** _Relentless, evidence‑driven, and respectful._ I combine surveillance‑grade audit & compliance discipline with a white‑glove customer approach and deep kernel instrumentation. Goal: minimize guesswork, prove with repeatable measurements, and communicate clearly in business terms.

**Models I operationalize:**
- **The W’s** (Who/What/When/Where/Why/How) → scope first, then act.
- **Fishbone (Ishikawa)** → hypothesis map across bones: Network/Peering; Host/Kernel/NIC; Capacity/Matchmaking; Application/Tick; DNS/Geo/Policy; Change/Config; DDoS/Security.
- **OODA** (Observe → Orient → Decide → Act) & **PDCA** (Plan → Do → Check → Act) → tight iterations with safe, measurable experiments.
- **SRE RED/USE** → Requests/Errors/Duration & Utilization/Saturation/Errors lenses.

**Communication style:** White‑glove, fact‑first, visuals over log walls, regular cadence, precise asks when escalating.

---

## 1) The W’s — Question‑First Intake (Full Checklist)
Document answers in an **evidence log** (timestamps, commands, artifact hashes). Don’t proceed without clarity.

**Who** — impacted players (#/%, ISPs/ASNs e.g., NTT/KDDI/SoftBank), any VIP/pro users, initial reporters/channels, owners/approvers (matchmaking policy, provider contracts).  
**What** — degraded signals (**RTT**, **jitter**, **loss**, timeouts, rubber‑banding), platforms (PC/console/mobile), server regions (Tokyo/Osaka/backup), recent changes (deploys, drivers, scrubbing, BGP/peering), mitigations tried + results.  
**When** — JST window (e.g., **19:00–24:00**), first‑seen date, nightly vs intermittent, controls (JP mornings; KR/TW evenings).  
**Where** — player prefecture/city; server DC/AZ/rack/TOR; path hop/ASN/IX where degradation begins.  
**Why** — initial hypotheses: eyeball congestion/peering; scrubbing hairpin; host saturation (softirq/IRQ/NIC/NUMA); capacity overflow; routing diffs (v4≠v6/BGP); app stalls; DNS/geo mis‑steer; change regression.  
**How** — matchmaking policy; current telemetry; access model (shell/bastion); explicit SLIs/SLOs for validation.

> **Deliverable:** 1‑page W’s summary attached to the evidence log.

---

## 2) Access & Environment Discovery
- **Shell access** (root/sudo/read‑only) via bastion? OS & kernel versions.  
- **Cloud**: provider/instance families, **CPU steal/throttle** visibility, ENA/SR‑IOV, accelerators (Anycast/Global Accelerator).  
- **Bare metal**: NIC model/firmware (mlx5/ixgbe/i40e/bnxt), **RSS/RPS/XPS**, ring sizes, IRQ layout, **NUMA** pinning.  
- **Network gear**: TOR/edge visibility (SNMP/telemetry), IX presence (JPNAP/JPIX/BBIX).  
- **Observability**: Prometheus/Grafana, ELK/Loki, OTel — or plan to bootstrap.

**Provider context:** DCs/AZs, how they detect incidents, what counters they can export (edge/TOR/IX, BGP/scrubbing), engagement mode (we run / they run / screen‑share).

---

## 3) The Case (C) — Direct Answers

### 3.1 How I confirm the issue & collaborate with the provider
1. **Prove the symptom**: enable/collect **client RUM** (RTT/jitter/loss p50/p95/p99; tags: **ISP/ASN**, **IPv4/6**, **serverID**) and run **synthetic probes** (Tokyo/Osaka on NTT/KDDI/SoftBank) — `mtr` + `iperf3 -u` — focused on **19:00–24:00 JST**. Build **JST heatmaps**.  
2. **Correlate layers**: host (softirq/IRQ, NIC drops, qdisc backlog, CPU steal) ↔ path (Paris MTR forward/reverse, first bad hop/ASN/IX).  
3. **White‑glove with provider**: send a one‑pager (impact window, visuals), attach pathproof, and request **edge/TOR/IX** counters + **A/B routing** via alternate transit/POP for a canary (10–20%).  
4. **Mitigate & verify**: promote the winning path, or tune host (IRQ/RSS/NUMA/fq_codel), adjust scrubbing, scale/weight JP pools. Validate against SLOs across **two evenings**.

### 3.2 Extra info (i): Third‑party host with weak metrics — how I get signal
- **Players/support** → time‑aligned ticket volume & categories.  
- **Client RUM** → add minimal telemetry to netcode; ship histograms.  
- **Self‑managed probes** → deploy in Tokyo/Osaka over major ISPs; schedule `mtr`/`iperf3 -u`.  
- **If provider can’t export**: give them **read‑only command pack**; require artifact hashes (chain of custody).

### 3.3 Extra info (ii): Mix of cloud & bare metal — W’s for each + L2→L7 proof
- **Cloud**: check **CPU steal/throttle**, vNIC features/offloads, AZ placement, DDoS region/policy; try **accelerator/alternate transit** canary.  
- **Bare metal**: validate NIC firmware/driver, **IRQ/RSS/XPS**, **NUMA**, TOR uplink headroom, IX peering.  
- **L2→L7**: MTU/frag; UDP/TCP path jitter/loss; socket queue/backlog; app tick/frame timing; DNS geo/TTL behavior (v4 vs v6 steering).

### 3.4 Data & metrics required to confirm the issue
- **Player RUM**: RTT/jitter/loss histograms with tags (**ISP/ASN**, **IPv4/6**, **serverID**, city, device), **5–10 min** bins with **JST** timestamps.  
- **Server/Host**: CPU user/sys/**steal**, run queue; **softirq/IRQ** rates; NIC `ethtool -S` drops/rings; **qdisc** backlog; per‑socket RTT/loss; **PPS/BPS** per process; **time sync**.  
- **Network/Path**: Paris MTR fwd/rev; hop/ASN/IX of first degradation; **IPv4 vs IPv6** split; **edge/TOR/IX** utilization/drops; **BGP/scrubbing** logs.  
- **Business**: abandon/reconnect/complaint rates aligned to the window.

### 3.5 Tooling I need in place (incl. custom craftables)
- **Off‑the‑shelf**: Prometheus/Grafana (RUM histograms), OTel, ELK/Loki; RIPE/ThousandEyes/Catchpoint or DIY probes; node_exporter, snmp_exporter.  
- **Custom**:  
  - `udp_rtt_buckets.bpf` — per‑socket RTT histograms keyed by serverID (Prom exporter).  
  - `nicq_watch.bpf` — sample qdisc backlog + NIC ring occupancy; alert on thresholds.  
  - `tick_drift_probe.bpf` — detect app tick/frame stalls vs wall clock.  
  - `paris_mtr_cron.sh` — cronable UDP MTR with JSON + SHA256 for custody.  
  - *(Insert repo links below in Appendix 8.3.)*

### 3.6 Debug steps — Fishbone (Ishikawa) applied to latency
```
                                 ┌──────── Application/Tick ────────┐
                                 │ GC pauses, locks, serialization  │
                                 └──────────────────────────────────┘
  ┌──────── Network/Peering ─────┐   ┌────── Capacity/Matchmaking ──┐   ┌───── DNS/Geo/Policy ───┐
  │ ISP congestion, peering, IX  │   │ overflow to remote DC/AZ     │   │ mis-geo, TTL, v4/v6    │
  └──────────────────────────────┘   └──────────────────────────────┘   └────────────────────────┘
               ┌──────────── Host/Kernel/NIC ────────────┐           ┌──────── Change/Config ───────┐
               │ softirq, IRQ, ring, NUMA, fq_codel      │           │ recent deploy/policy change  │
               └─────────────────────────────────────────┘           └──────────────────────────────┘
                                 ┌──── DDoS/Security ────┐
                                 │ scrubbing hairpin, QoS│
                                 └───────────────────────┘
```
**Per bone → Hypothesis → Tests → Data → Mitigations:**  
- **Network/Peering**: Paris MTR fwd/rev; IPv4/6 split; **A/B** transit/POP. → Shift route/peering; add IX capacity.  
- **Host/Kernel/NIC**: `runqlat`, `softirqs`, `ethtool -S`, `tc -s`. → Tune IRQ/RSS/XPS, fq_codel, ring sizes, NUMA pin.  
- **Capacity/Matchmaking**: pool utilization & serverID distribution. → Scale JP pools; reweight to healthy DC/AZ.  
- **Application/Tick**: uprobes around tick loop; flamegraphs. → GC/lock tuning; pacing.  
- **DNS/Geo/Policy**: resolver ASNs; answer mapping; TTL. → geoDB fixes; TTL tuning.  
- **Change/Config**: 72h change audit; rollback. → Revert/patch; CAPA.  
- **DDoS/Security**: scrubbing logs; latency by policy. → Nearest scrubbing region; policy exception for UDP ports.

### 3.7 Working with the game‑server provider — white‑glove playbook
- **Engagement modes**: (1) We run; (2) They run our **script pack**; (3) Screen‑share we drive.  
- **What we send**: one‑pager (JST window, impact), heatmaps, host overlays, Paris MTR (hop/ASN highlighted).  
- **Requests (48h)**: edge/TOR/IX counters; peering matrix; BGP/scrubbing notes; server placement/noisy‑neighbor flags; approve **A/B routing** canary (10–20%).  
- **Validation**: compare p95 RTT/jitter/loss over two evenings; promote winning path; lock in peering/tuning; publish concise player status.

---

## 4) End‑to‑End Procedure (Line‑by‑Line Execution)
1. **Intake using W’s** → 1‑pager + evidence log (hash artifacts).  
2. **Baseline** → 14‑day RUM & synthetic probes; **JST** heatmaps (per ISP).  
3. **Segment** → ISP/ASN, IPv4/6, server pool/AZ; ensure no cross‑region matchmaking.  
4. **Instrument hosts** → exporters + **eBPF** (softirq/runq/NIC/qdisc/tick drift).  
5. **Pathproof** → Paris MTR fwd/rev from multiple JP ISPs during **19:00–24:00 JST**.  
6. **Correlate** → RUM spikes ↔ host drops/softirq ↔ hop/ASN degradation.  
7. **Mitigate** → A/B transit/POP; host tuning; scrubbing policy; capacity/weights.  
8. **Validate** → p95 RTT/jitter/loss back to baseline for **two evenings**.  
9. **Root cause & CAPA** → document; standardize; add permanent probes/dashboards.  
10. **Comms** → white‑glove updates to studio; concise player status.

---

## 5) Examples: Commands, Scripts, and eBPF/DTrace

### 5.1 Userland quick kit
```bash
# Forward UDP path shape
mtr -u -w -z --json <JP_SERVER_IP> -c 200 > mtr_fwd.json

# Reverse path (run ON server)
mtr -u -w -z --json <PROBE_IP> -c 200 > mtr_rev.json

# NIC & qdisc
ethtool -S <IFACE> | egrep 'rx_dropped|tx_dropped|rx_no_buffer|fifo|missed'
tc -s qdisc show dev <IFACE>

# Kernel/IP stack errors & sockets
nstat -az | egrep 'InErrs|IpReasmFails|UdpInErrors|TcpRetransSegs'
ss -u -i | head -100

# Time sync
chronyc tracking; chronyc sources -v
```

### 5.2 Synthetic probe (cronable)
```bash
#!/usr/bin/env bash
set -euo pipefail
TARGETS=("JP_DC_A_IP" "JP_DC_B_IP")
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p artifacts/$STAMP
for t in "${TARGETS[@]}"; do
  mtr -u -w -z --json -c 200 "$t" > "artifacts/$STAMP/mtr_fwd_${t}.json"
done
iperf3 -u -b 50M -t 30 -c JP_DC_A_IP --json > "artifacts/$STAMP/iperf_jp_a.json"
sha256sum artifacts/$STAMP/* > "artifacts/$STAMP/SHA256SUMS"
```

### 5.3 bpftrace (quick probes)
```bash
# SoftIRQ latency histogram
bpftrace -e 'kprobe:__do_softirq { @ts[comm] = nsecs; }
kretprobe:__do_softirq /@ts[comm]/ { @lat[comm] = hist((nsecs-@ts[comm])/1000); delete(@ts[comm]); }'

# Run queue latency
bpftrace -e 'tracepoint:sched:sched_wakeup { @w[arg0] = nsecs; }
tracepoint:sched:sched_switch /@w[pid]/ { @runqlat[comm] = hist((nsecs-@w[pid])/1000); delete(@w[pid]); }'
```

### 5.4 BCC Python (sketch)
```python
from bcc import BPF
prog = r"""
#include <uapi/linux/ptrace.h>
BPF_HISTOGRAM(lat, u64);
int kprobe__udp_recvmsg(struct pt_regs *ctx) {
  u64 d = bpf_ktime_get_ns() % 1000000; # sketch: replace with real rtt calc
  lat.increment(bpf_log2l(d));
  return 0;
}
"""
b = BPF(text=prog)
print("Collecting... Ctrl-C to end")
try:
  b.trace_print()
except KeyboardInterrupt:
  b["lat"].print_log2_hist("udp_recv_ns")
```

---

## 6) Provider Command Pack & Escalation Template

### 6.1 Safe read‑only pack (provider can copy‑paste)
```bash
for i in $(ls /sys/class/net | grep -E 'eth|ens|eno|enp'); do
  echo "== $i =="
  ethtool -S $i | egrep 'rx_dropped|tx_dropped|rx_fifo_errors|rx_no_buffer|rx_missed|tx_errors'
done
tc -s qdisc show dev <UPLINK_IFACE>
mpstat -P ALL 1 5
cat /proc/softirqs | sed -n '1,20p'
mtr -u -w -z -c 100 --report <PROBE_IP>
```

### 6.2 Escalation template (white‑glove)
> **Issue:** JP p95 RTT 35→120 ms, **19:00–23:30 JST** since YYYY‑MM‑DD; ISPs NTT/KDDI/SoftBank. Pools: Tokyo‑A/B (IDs attached).  
> **Evidence:** RUM heatmaps; host NIC/qdisc overlays; Paris‑MTR showing first bad hop at **ASN ####** (screenshot + JSON).  
> **Requests (48h):** Edge/TOR/IX utilization & drop counters; transit/peering matrix; BGP policy & scrubbing notes; server placement/noisy‑neighbor flags; approval for **A/B routing** via alternate JP transit/POP for a 10–20% cohort.  
> **Success:** Restore p95 RTT/jitter/loss to baseline for two consecutive evenings.

---

## 7) Acceptance Criteria (Definition of Done)
- Two consecutive evenings: JP cohort p95 **RTT ≤ target**, **jitter ≤ target**, **loss ≤ target**.  
- Complaint volume returns to baseline; no regressions elsewhere.  
- Durable fix: peering/capacity/tuning committed; minimal exported metrics from provider in place.  
- Runbooks updated; permanent probes/dashboards online.

---

## 8) Appendices (Evidence Log, PromQL, Tool Links)

### 8.1 Evidence Log Template
```
Date/Time (UTC/JST):
Operator:
Action/Command:
Host/Region:
Artifact Path + SHA256:
Observation:
Next Step:
```

### 8.2 Heatmap Query Hint (PromQL)
```promql
histogram_quantile(0.95, sum(rate(game_rtt_ms_bucket{region="jp"}[5m])) by (le, hour, isp))
```

### 8.3 Your Tool Links (insert your repos)
- `udp_rtt_buckets.bpf` → **[ADD_LINK_HERE]**
- `nicq_watch.bpf` → **[ADD_LINK_HERE]**
- `tick_drift_probe.bpf` → **[ADD_LINK_HERE]**
- `paris_mtr_cron.sh` → **[ADD_LINK_HERE]**
- `jp_evening_heatmap.py` → **[ADD_LINK_HERE]**

---

**Outcome:** This single document both **answers the case prompts** and codifies my **methodology** (W’s + Fishbone + OODA/PDCA), with practical examples (userland + custom + in‑kernel) and a provider‑friendly playbook. It moves from **anecdote → proof → mitigation → durable fix** with professional, white‑glove communication.

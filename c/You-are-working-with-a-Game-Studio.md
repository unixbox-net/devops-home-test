### C. You are working with a Game Studio that has received player reports from their Japanese players stating that during the evening their latency is much higher than usual, affecting their match quality. How do you go about confirming the issue and working with the game server provider to resolve it?

-  Extra info:
    -  i. You know that their gameservers are hosted by a third party which does not have good metrics and visibility
    - ii. You know that the gameservers are in a mix of cloud and bare metal datacenters
      
- What data and metrics do you need to see to be able to confirm the issue?
- What tooling would you need to be in place to help you confirm the problem?
- What debugging steps would you work through to help get a better understanding of the issue?
- How would you go about working with the gameserver provider to resolve the issue?


# JP Evening Latency — Case Runbook & Troubleshooting Methodology
_A single, self-contained playbook that both **answers the specific case questions** and documents **how I troubleshoot** using the **W’s**, **Fishbone (Ishikawa)**, and concrete examples across userland tools, custom diagnostic scripts, and **in‑kernel instrumentation** (eBPF/DTrace). It doubles as a living copy‑paste command sheet._

---

## Table of Contents
- [0) Ethos & Models](#0-ethos--models)
- [1) The W’s — Question-First Intake (Full Checklist)](#1-the-ws--question-first-intake-full-checklist)
- [2) Access & Environment Discovery](#2-access--environment-discovery)
- [3) Addressing the Case Questions Directly](#3-addressing-the-case-questions-directly)
  - [3.1 How do you confirm the issue and work with the provider?](#31-how-do-you-confirm-the-issue-and-work-with-the-provider)
  - [3.2 Extra info (i): Third-party with poor visibility — where are indicators coming from?](#32-extra-info-i-third-party-with-poor-visibility--where-are-indicators-coming-from)
  - [3.3 Extra info (ii): Mix of cloud and bare metal — W’s for each + L2–L7 proof plan](#33-extra-info-ii-mix-of-cloud-and-bare-metal--ws-for-each--l2l7-proof-plan)
  - [3.4 What data & metrics are needed to confirm the issue?](#34-what-data--metrics-are-needed-to-confirm-the-issue)
  - [3.5 What tooling should be in place (incl. custom craftables)?](#35-what-tooling-should-be-in-place-incl-custom-craftables)
  - [3.6 What debugging steps to understand the issue (Fishbone applied)?](#36-what-debugging-steps-to-understand-the-issue-fishbone-applied)
  - [3.7 How to work with the game server provider to resolve it (white-glove)?](#37-how-to-work-with-the-game-server-provider-to-resolve-it-white-glove)
- [4) End-to-End Procedure (Line-by-Line Execution)](#4-end-to-end-procedure-line-by-line-execution)
- [5) Examples: Commands, Scripts, and eBPF/DTrace](#5-examples-commands-scripts-and-ebpfdtrace)
- [6) Provider Command Pack & Escalation Template](#6-provider-command-pack--escalation-template)
- [7) Acceptance Criteria (Definition of Done)](#7-acceptance-criteria-definition-of-done)
- [8) Appendices (Evidence Log, PromQL, Tool Links)](#8-appendices-evidence-log-promql-tool-links)

---

## 0) Ethos & Models
**Ethos:** _Relentless, evidence-driven, and respectful._ I combine surveillance-grade audit discipline with a white‑glove customer approach and deep kernel instrumentation. Goal: minimize guesswork, confirm with repeatable measurement, and communicate clearly.

**Models I operationalize:**
- **The W’s** (Who/What/When/Where/Why/How) — clarify scope first.
- **Fishbone (Ishikawa)** — structure hypotheses across bones (Network/Peering; Host/Kernel/NIC; Capacity/Matchmaking; Application/Tick; DNS/Geo/Policy; Change/Config; DDoS/Security).
- **OODA** & **PDCA** — iterate rapidly with small, safe experiments.
- **SRE RED/USE** — Requests/Errors/Duration & Utilization/Saturation/Errors lenses.

---

## 1) The W’s — Question-First Intake (Full Checklist)
Capture answers in an **evidence log** (timestamps, commands, artifact hashes). Don’t proceed without a crisp scope.

**Who** — impacted players (#/%, ISPs/ASNs like NTT/KDDI/SoftBank), VIPs/pros, reporters/channels, owners/approvers (matchmaking, provider contracts).  
**What** — degraded signals (RTT/jitter/loss/timeouts/rubber-banding), platforms (PC/console/mobile), server regions (Tokyo/Osaka/backups), recent changes (deploys, drivers, DDoS, peering/BGP), prior mitigations.  
**When** — JST windows (e.g., 19:00–24:00), start date, nightly vs intermittent, control cohorts (JP mornings; KR/TW evenings).  
**Where** — player prefectures/cities, server DC/AZ/rack/TOR, path hop/ASN/IX where degradation begins.  
**Why** — initial hypotheses (eyeball congestion/peering; scrubbing hairpin; host saturation; capacity mismatch; routing diffs; app stalls; DNS/geo; change regression).  
**How** — matchmaking policy; current telemetry; access model (shell/bastion); validation SLIs/SLOs.

> **Deliverable:** 1‑page W’s summary attached to the evidence log.

---

## 2) Access & Environment Discovery
- **Shell access** (root/sudo/read-only), bastion? OS & kernel versions.  
- **Cloud**: provider, instance families, **CPU steal/throttle** visibility, ENA/SR‑IOV, accelerators (Anycast/Global Accelerator).  
- **Bare metal**: NIC models & firmware (mlx5/ixgbe/i40e/bnxt), **RSS/RPS/XPS**, ring sizes, IRQ layout, **NUMA** pinning.  
- **Network gear**: TOR/edge visibility (SNMP/telemetry), IXs (JPNAP/JPIX/BBIX).  
- **Observability**: Prometheus/Grafana, ELK/Loki, OTel — or plan to bootstrap.

**Provider context:** which DCs/AZs, how they detect problems, what they can export (edge/TOR/IX utilization/drops, BGP/scrubbing), and engagement mode (we run/they run/screen-share).

---

## 3) Addressing the Case Questions Directly

### 3.1 How do you confirm the issue and work with the provider?
1) **Confirm with data**: enable/collect **RUM** (RTT/jitter/loss p50/p95/p99; tags: ISP/ASN, IPv4/6, serverID) and **synthetic probes** (Tokyo/Osaka; `mtr` + `iperf3 -u`) across the **evening window**. Build **JST heatmaps** to show the spike.  
2) **Correlate** with **host** (softirq/IRQ, NIC drops, qdisc backlog, CPU steal), and **path** (Paris MTR fwd/rev; hop/ASN where jitter/loss begins).  
3) **Engage provider white‑glove**: send a concise one‑pager (impact window, graphs), attach pathproof, and request **edge/TOR/IX** counters + **A/B routing** via alternate transit/POP for a canary.  
4) **Mitigate & validate**: if canary wins, promote path; else tune host (IRQ/RSS/NUMA/fq_codel), adjust scrubbing, scale/weight JP pools. Validate vs SLOs over two evenings.

### 3.2 Extra info (i): Third-party with poor visibility — where are indicators coming from?
- **Players/support** (tickets, social, Discord) → volume/time correlations.  
- **Client RUM** (add lightweight telemetry to netcode).  
- **Self-managed probes** from JP ISPs (Tokyo/Osaka) → scheduled `mtr`/`iperf3 -u`.  
- **Minimal provider exports**: request read‑only **edge/TOR/IX** counters, **BGP/scrubbing** logs; if they can’t, provide **scripted commands** to run and return artifacts (hashes for chain of custody).

### 3.3 Extra info (ii): Mix of cloud and bare metal — W’s for each + L2–L7 proof plan
- **Cloud**: check **CPU steal/throttle**, NIC virtualization (ENA, offloads), placement (AZ), DDoS layer/region; try **alternate transit/accelerator** for canary.  
- **Bare metal**: validate NIC firmware/driver, **IRQ/RSS/XPS**, **NUMA**, TOR uplink capacity, IX peering.  
- **L2–L7 proof**: MTU/fragmentation; UDP/TCP path loss/jitter (Paris MTR); socket queues/pacing; app tick/frame timing; DNS geo/TTL behavior.

### 3.4 What data & metrics are needed to confirm the issue?
- **Player RUM**: RTT, jitter, loss (histograms) with tags: ISP/ASN, IPv4/6, serverID, city, device. 5–10 min bins; **JST**.  
- **Server/Host**: CPU user/sys/**steal**, run queue, **softirq/IRQ** rates; NIC `ethtool -S` drops/rings; **qdisc** backlog; per‑socket RTT/loss; **PPS/BPS** per process; **time sync** status.  
- **Network/Path**: Paris MTR (forward + reverse), hop/ASN/IX where degradation starts; **IPv4 vs IPv6** divergences; **edge/TOR/IX** counters; **BGP/scrubbing** logs.  
- **Business**: abandon/reconnect rates, complaint volumes — correlated to latency.

### 3.5 What tooling should be in place (incl. custom craftables)?
- **Off‑the‑shelf**: Prometheus/Grafana (RUM histograms), OTel, ELK/Loki; RIPE/ThousandEyes/Catchpoint or DIY probes; node_exporter, snmp_exporter.  
- **Custom** (my craftables):  
  - `udp_rtt_buckets.bpf` — per‑socket RTT histograms keyed by serverID (Prom exporter).  
  - `nicq_watch.bpf` — sample qdisc backlog + NIC ring occupancy; alert on thresholds.  
  - `tick_drift_probe.bpf` — detect app tick/frame stalls vs clock.  
  - `paris_mtr_cron.sh` — cronable UDP MTR with JSON + SHA256 for custody.

### 3.6 What debugging steps to understand the issue (Fishbone applied)?
- **Network/Peering**: Hypothesis — evening eyeball congestion. _Tests_ — Paris MTR fwd/rev; IPv4/6 split; canary via alternate transit/POP. _Mitigations_ — shift route/peering; add IX capacity.  
- **Host/Kernel/NIC**: Hypothesis — softirq/IRQ/ring overflow. _Tests_ — `runqlat`, `softirqs`, `ethtool -S`, `tc -s`. _Mitigations_ — IRQ/RSS/XPS, fq_codel, ring sizes, NUMA pin.  
- **Capacity/Matchmaking**: Hypothesis — remote overflow/AZ link hot. _Tests_ — per‑pool utilization; serverID distribution. _Mitigations_ — scale/weight JP pools.  
- **Application/Tick**: Hypothesis — frame/GC stalls. _Tests_ — uprobes around tick loop; flamegraphs. _Mitigations_ — GC/lock tuning, pacing.  
- **DNS/Geo/Policy**: Hypothesis — mis‑geo/TTL steering. _Tests_ — resolver ASNs; answer mapping. _Mitigations_ — geoDB fixes, TTL tuning.  
- **Change/Config**: Hypothesis — recent regression. _Tests_ — 72h change audit; rollback. _Mitigations_ — revert/patch; CAPA.  
- **DDoS/Security**: Hypothesis — scrubbing hairpin/queuing. _Tests_ — provider policy logs, latency by policy. _Mitigations_ — policy exception/nearest scrubbing region.

### 3.7 How to work with the game server provider to resolve it (white-glove)?
- **Engagement modes**: (1) We run; (2) They run our **script pack**; (3) Screen‑share we drive.  
- **Artifacts we send**: one‑pager (JST window, impact), heatmaps, host overlays, Paris MTR (hop/ASN).  
- **Requests (48h)**: edge/TOR/IX counters; peering matrix; BGP/scrubbing notes; server placement/noisy‑neighbor; approve **A/B routing** canary (10–20%).  
- **Validation**: measure p95 RTT/jitter/loss over two evenings; promote winning path; lock in peering/tuning.

---

## 4) End-to-End Procedure (Line-by-Line Execution)
1. Intake using W’s → 1‑pager + evidence log (hash artifacts).  
2. Baseline → 14‑day RUM & synthetic probes; JST heatmaps (per ISP).  
3. Segment → ISP/ASN, IPv4/6, server pool/AZ; confirm no cross‑region matchmaking.  
4. Instrument hosts → exporters + **eBPF** (softirq/runq/NIC/qdisc/tick drift).  
5. Pathproof → Paris MTR fwd/rev from multiple JP ISPs during 19:00–24:00 JST.  
6. Correlate → RUM spikes ↔ host drops/softirq ↔ hop/ASN degradation.  
7. Mitigate → A/B transit/POP; host tuning; scrubbing policy; capacity/weights.  
8. Validate → p95 RTT/jitter/loss back to baseline for **2 evenings**.  
9. Root cause & CAPA → document; standardize; add permanent probes/dashboards.  
10. Comms → white‑glove updates to studio; concise player status.

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
  u64 d = bpf_ktime_get_ns() % 1000000; // sketch: replace with real rtt calc
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

### 6.1 Safe read-only pack (provider can copy-paste)
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

### 6.2 Escalation template (white-glove)
> **Issue:** JP p95 RTT 35→120 ms, 19:00–23:30 JST since YYYY‑MM‑DD; ISPs NTT/KDDI/SoftBank. Pools: Tokyo‑A/B (IDs attached).  
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

**Outcome:** This file directly answers the case prompts and embeds a rigorous method (W’s + Fishbone + OODA/PDCA), with practical examples (userland + custom + in‑kernel) and a white‑glove provider playbook. Designed to move from anecdote → proof → mitigation → durable fix.

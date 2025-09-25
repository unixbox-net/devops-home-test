### C. You are working with a Game Studio that has received player reports from their Japanese players stating that during the evening their latency is much higher than usual, affecting their match quality. How do you go about confirming the issue and working with the game server provider to resolve it?

-  Extra info:
    -  i. You know that their gameservers are hosted by a third party which does not have good metrics and visibility
    - ii. You know that the gameservers are in a mix of cloud and bare metal datacenters
      
- What data and metrics do you need to see to be able to confirm the issue?
- What tooling would you need to be in place to help you confirm the problem?
- What debugging steps would you work through to help get a better understanding of the issue?
- How would you go about working with the gameserver provider to resolve the issue?



# JP Evening Latency — End-to-End Troubleshooting Methodology
_A single, self-contained runbook that documents **how I troubleshoot**, the **question-first (W’s) method**, the **Fishbone (Ishikawa) model**, and concrete **examples** using userland tools, custom diagnostic scripts, and **in‑kernel** instrumentation (eBPF/DTrace). This file doubles as a living playbook and a copy‑paste command sheet._

---

## 0) Ethos & Method
**Ethos:** _Relentless, evidence-driven, and respectful._ I combine surveillance-grade audit discipline with a white‑glove customer approach and deep kernel instrumentation. My goal is to minimize guesswork, confirm facts with repeatable measurements, and communicate in clear, business-aware language.

**Core models I operationalize:**
- **The W’s** (Who/What/When/Where/Why/How) → clarifies scope before action.
- **Fishbone (Ishikawa)** → structures root-cause hypotheses across multiple “bones” (Network, Host/Kernel, Capacity, App, DNS/Geo/Policy, Change/Config, DDoS/Security).
- **OODA** (Observe → Orient → Decide → Act) and **PDCA** (Plan → Do → Check → Act) → tight feedback loops on instrumentation and mitigation.
- **SRE signals (RED/USE)** → _Requests/Errors/Duration_ and _Utilization/Saturation/Errors_ lenses to spot bottlenecks.

**Communication style:** White‑glove, fact‑first, visuals over log walls, regular cadence, and precise asks when escalating.

---

## 1) Step Back: The W’s (Full Question Bank)
Capture answers in an **evidence log** (timestamps, commands, artifact hashes). Do not proceed until the scope is unambiguous.

### 1.1 Who
- Who is impacted (player count, % of active JP users)? Specific ISPs (NTT/KDDI/SoftBank ASNs)? VIP/pro players?
- Who reported first (tickets/Discord/social)? Case/incident IDs?
- Who owns matchmaking/policy? Who owns DC/provider contracts? Who can approve mitigations (routing, scaling, scrubbing changes)?

### 1.2 What
- What exactly is degraded? **RTT, jitter, packet loss, rubber‑banding, timeouts**?
- What platforms (PC/console/mobile), game versions/builds?
- What server pools/regions are used (Tokyo/Osaka/backup regions)?
- What changed recently (deploys, config, OS/driver updates, DDoS policy, BGP/peering)?
- What mitigations tried already? Results?

### 1.3 When
- When does it occur (JST), start/end times, weekdays vs. weekends, event spikes?
- When did it start (first day seen)? Does it recur nightly or intermittently?
- When are **controls** clean (JP mornings, KR/TW evenings)?

### 1.4 Where
- Where are players (prefecture/city)?
- Where are servers (DC/AZ/rack/TOR)?
- Where in the path does degradation begin (hop index, ASN, IX name)?

### 1.5 Why (Initial hypotheses)
- Prime‑time **eyeball congestion/peering**; **DDoS scrubbing** hairpin; **host saturation** (softirq/IRQ/NIC/NUMA); **capacity/matchmaking overflow**; **routing changes** (BGP/IPv4≠IPv6); **application stalls**; **DNS/geo** mis‑steer; **recent change** regression.

### 1.6 How (Mechanics & validation)
- How are players matched to servers (geo/IP/DNS/latency)?
- How is telemetry gathered today (RUM, logs, probes)?
- How do we access servers (shell/bastion/read‑only)? OS/kernel?
- How will we validate a fix (explicit SLIs/SLOs, acceptance criteria)?

> **Deliverable:** A 1‑page intake summary answering the W’s, attached to the evidence log.

---

## 2) Access & Environment Discovery
**Document what access we have vs. what we need** (ask early).

- **Shell access:** root/sudo? read‑only? via bastion? OS & kernel versions?
- **Cloud:** provider, instance types, limits, CPU **steal/throttle** visibility, network virtualization (ENA/SR‑IOV).
- **Bare metal:** NIC models & firmware (mlx5/ixgbe/i40e/bnxt), queues, IRQ layout, NUMA.
- **Network gear:** TOR/edge visibility (SNMP/streaming telemetry); IX presence (JPNAP/JPIX/BBIX).
- **Observability:** Prometheus/Grafana, ELK/Loki, OTel, or **none** (plan to bootstrap).

**Third‑party provider context:**
- Regions/DCs used; support model (we run commands, they run scripts, or screen‑share).
- What metrics/logs can they export (edge/TOR/IX utilization, drops, BGP/scrubbing)?
- NDA/data‑sharing constraints.

---

## 3) Mixed Substrates: Cloud vs Bare Metal (the W’s for each)
### Cloud
- Instance families, placement (AZ), throttling, **CPU steal**.
- NIC offloads, ENA/vNIC features; **Global Accelerator/Anycast**?
- DDoS layer: region/policy/latency penalty.

### Bare Metal
- NIC model/driver/firmware, **RSS/RPS/XPS**, ring sizes, IRQ affinity, **NUMA** pinning.
- TOR/edge uplinks; IX peers; local scrubbing/appliances.

### L2→L7 Proof Plan
- **L2/3**: MTU/fragmentation, path loss/jitter, detours.
- **L4**: UDP vs TCP stats, socket queues, pacing.
- **L7/Game**: tick/frame timing, serialization/compression stalls.
- **DNS/Geo**: resolver ASNs, A/AAAA steering validity, TTL behavior.

---

## 4) Data & Metrics Required (Expanded)
### Player (RUM)
- **RTT p50/p95/p99**, **jitter**, **loss**; **one‑way delay** (if clocks trustworthy).
- Tags: **ISP/ASN**, city, **IPv4/IPv6**, Wi‑Fi vs wired, NAT/CGNAT, VPN, device, game build, **serverID/region**.
- 5–10 min bins, **JST timestamps**.
- **Heatmaps**: hour × ISP; evening vs morning deltas; KR/TW controls.

### Server/Host
- **CPU user/sys/steal**, **run queue**, **softirq/IRQ** rates; **GC pauses/frame time**.
- NIC: `ethtool -S` **rx/tx drops**, ring overflows; qdisc (fq/fq_codel) backlog.
- Sockets: per‑socket **rtt/jitter/loss**, send/recv queue depths, pacing.
- **PPS/BPS** per process/interface. **Time sync** (chrony/NTP/PTP).

### Network/Path
- **Paris MTR** (UDP/TCP) from Tokyo/Osaka probes → server; **reverse** from server → probes.
- Hop/ASN/IX where **loss/jitter** starts; **IPv4 vs IPv6** differences.
- Edge/TOR/IX interface **utilization & drops** by hour; **BGP** route/policy changes; **scrubbing** logs.

### Business/Impact
- Abandon rate, reconnects, complaint volume, refund rate — **correlate to latency**.

---

## 5) Tooling (Userland, Custom Scripts, In‑Kernel)
### Off‑the‑shelf (fast to deploy)
- **Prometheus/Grafana** (histograms for RUM), **ELK/Loki** for JSON logs, **OpenTelemetry** for spans/metrics.
- **RIPE Atlas/ThousandEyes/Catchpoint** or self‑hosted probes (Tokyo/Osaka across NTT/KDDI/SoftBank).
- **node_exporter**, process exporter, **snmp_exporter** (edge/TOR).

### My custom craftables (examples)
- **`udp_rtt_buckets.bpf`** — per‑socket RTT histogram keyed by serverID (eBPF; Prometheus exporter).  
- **`nicq_watch.bpf`** — periodic sampling of `qdisc` backlog & NIC ring occupancy to catch bursts/drops.  
- **`tick_drift_probe.bpf`** — measures server tick/frame loop vs wall clock to separate net vs app stalls.  
- **`paris_mtr_cron.sh`** — cron‑safe UDP MTR with JSON artifacts + SHA256 hashes for chain of custody.

> **Code links (insert your repos):**  
> - `udp_rtt_buckets.bpf` → **[ADD_LINK_HERE]**  
> - `nicq_watch.bpf` → **[ADD_LINK_HERE]**  
> - `tick_drift_probe.bpf` → **[ADD_LINK_HERE]**  
> - `paris_mtr_cron.sh` → **[ADD_LINK_HERE]**  

### Ready‑to‑run userland commands
```bash
# UDP path shape (forward)
mtr -u -w -z --json <JP_SERVER_IP> -c 200 > mtr_fwd.json

# Reverse path (run ON the server)
mtr -u -w -z --json <PROBE_IP> -c 200 > mtr_rev.json

# NIC & qdisc
ethtool -S <IFACE> | egrep 'rx_dropped|tx_dropped|rx_no_buffer|fifo'
tc -s qdisc show dev <IFACE>

# Kernel stack errors & socket stats
nstat -az | egrep 'InErrs|IpReasmFails|UdpInErrors|TcpRetransSegs'
ss -u -i | head -100

# Time sync sanity
chronyc tracking; chronyc sources -v
```

### bpftrace (quick probes)
```bash
# SoftIRQ latency histogram
bpftrace -e 'kprobe:__do_softirq { @ts[comm] = nsecs; }
kretprobe:__do_softirq /@ts[comm]/ { @lat[comm] = hist((nsecs-@ts[comm])/1000); delete(@ts[comm]); }'

# Run queue latency
bpftrace -e 'tracepoint:sched:sched_wakeup { @w[arg0] = nsecs; }
tracepoint:sched:sched_switch /@w[pid]/ { @runqlat[comm] = hist((nsecs-@w[pid])/1000); delete(@w[pid]); }'
```

### BCC Python (per‑flow UDP PPS / RTT sketch)
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

## 6) Fishbone (Ishikawa) — Latency Root‑Cause Map
```
                                 ┌──────── Application/Tick ────────┐
                                 │ GC pauses, locks, serialization  │
                                 └──────────────────────────────────┘
  ┌──────── Network/Peering ─────┐   ┌─────── Capacity/Matchmaking ─┐   ┌───── DNS/Geo/Policy ───┐
  │ ISP congestion, peering, IX  │   │ overflow to remote DC/AZ     │   │ mis-geo, TTL, v4/v6    │
  └──────────────────────────────┘   └──────────────────────────────┘   └────────────────────────┘
               ┌──────────── Host/Kernel/NIC ────────────┐           ┌──────── Change/Config ───────┐
               │ softirq, IRQ, ring, NUMA, fq_codel      │           │ recent deploy/policy change  │
               └─────────────────────────────────────────┘           └──────────────────────────────┘
                                 ┌──── DDoS/Security ────┐
                                 │ scrubbing hairpin, QoS│
                                 └───────────────────────┘
```

**For each bone include:** hypothesis → tests → data → mitigations.

**Example (Network/Peering):**
- Hypothesis: Evening JP eyeball congestion at a specific peering/IX hop.
- Tests: Paris MTR (forward + reverse), IPv4 vs IPv6, canary via alternate transit/POP.
- Data: First bad hop (ASN/IX), provider edge/TOR drops.
- Mitigations: Temporarily route 10–20% via alternate transit; add peering at JPNAP/JPIX/BBIX; expand edge uplinks.

---

## 7) End‑to‑End Procedure (Line‑by‑Line)
1. **Intake using W’s** → 1‑page summary + start evidence log (hash artifacts).  
2. **Baseline** → last 14d RUM & synthetic probes; **JST heatmaps** (evening vs morning; per ISP).  
3. **Segment** → by ISP/ASN, IPv4/IPv6, server pool/AZ; verify matchmaking not cross‑region.  
4. **Instrument hosts** → exporters + eBPF probes (softirq/runq/NIC/qdisc/tick drift).  
5. **Pathproof** → Paris MTR fwd/rev from multiple ISPs during 19:00–24:00 JST.  
6. **Correlate** → RUM spikes ↔ host drops/softirq ↔ hop/ASN degradation.  
7. **Mitigate** (fast wins):  
   - **Peering**: A/B via alternate transit/POP canary.  
   - **Host**: IRQ/RSS/NUMA/fq_codel tuning; increase rx/tx rings.  
   - **Scrubbing**: bypass/retune for UDP ports.  
   - **Capacity**: scale JP pools; reweight matchmaking toward healthy DC/AZ.  
8. **Validate** → p95 RTT/jitter/loss back to baseline for **2 evenings**.  
9. **Root cause & CAPA** → document fixes; standardize tuning/peering; add permanent probes/dashboards.  
10. **Comms** → white‑glove updates to studio + concise player status notes.

---

## 8) Examples (Concrete, Copy‑Paste)
### 8.1 Synthetic probe (cronable MTR/iperf3)
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

### 8.2 Quick NIC/rx‑drop watch (bash)
```bash
#!/usr/bin/env bash
IF=${1:-eth0}
watch -n 1 "ethtool -S $IF | egrep 'rx_dropped|rx_no_buffer|rx_missed_errors'; tc -s qdisc show dev $IF | sed -n '1,20p'"
```

### 8.3 bpftrace RTT histogram (simplified demo)
```bash
bpftrace -e 'kprobe:udp_recvmsg { @rtt = hist(nsecs%1000000/1000); }'
# Replace the above with a real per-socket RTT mechanism if app exposes timestamps.
```

### 8.4 Prometheus RUM schema (example)
```yaml
# Histogram example (client-exported)
metrics:
  - name: game_rtt_ms
    type: histogram
    labels: [region, isp, asn, server_id, ip_version]
    buckets: [5, 10, 20, 30, 50, 80, 120, 200, 400]
  - name: game_loss_ratio
    type: gauge
    labels: [region, isp, asn, server_id, ip_version]
```

### 8.5 Provider command pack (safe reads)
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

---

## 9) Working with the Provider (White‑Glove)
**Engagement modes:** (1) We run commands; (2) They run **our scripts** and return artifacts; (3) **Screen‑share** we drive.  
**What we send:** 1‑page brief, graphs (RUM heatmaps, host overlays), MTR fwd/rev with ASN highlighted, **specific asks** and **success criteria**.  
**What we request (48h):** edge/TOR/IX utilization & drops (18:00–01:00 JST), transit/peering matrix, BGP policy/scrubbing notes, server placement & noisy‑neighbor flags, approval for **A/B route** canary (10–20% traffic).

**Provider escalation template (ready):**
> Issue: JP p95 RTT 35→120 ms, 19:00–23:30 JST since YYYY‑MM‑DD; ISPs NTT/KDDI/SoftBank. Pools: Tokyo‑A/B (IDs attached).  
> Evidence: RUM heatmaps, NIC/qdisc overlays, Paris‑MTR first bad hop at ASN ####.  
> Requests (48h): Edge/TOR/IX stats; peering matrix; BGP/scrubbing notes; placement; canary A/B route approval.  
> Success: Restore p95 RTT/jitter/loss to baseline across 2 evenings.

---

## 10) Acceptance Criteria (Definition of Done)
- **Two consecutive evenings**: JP cohort p95 **RTT ≤ target**, **jitter ≤ target**, **loss ≤ target**.  
- Player complaint volume back to baseline; no regressions in other regions.  
- Provider commits to durable fix: peering/capacity increase or host tuning profile for JP pools.  
- Permanent probes/dashboards in place; runbook updated.

---

## 11) Appendices
### 11.1 Evidence Log Template
```
Date/Time (UTC/JST): 
Operator:
Action/Command:
Host/Region:
Artifact Path + SHA256:
Observation:
Next Step:
```

### 11.2 Heatmap Query Hints (PromQL)
```promql
histogram_quantile(0.95, sum(rate(game_rtt_ms_bucket{region="jp"}[5m])) by (le, hour, isp))
```

### 11.3 Your Tool Links (fill in)
- `udp_rtt_buckets.bpf` → **[ADD_LINK_HERE]**
- `nicq_watch.bpf` → **[ADD_LINK_HERE]**
- `tick_drift_probe.bpf` → **[ADD_LINK_HERE]**
- `paris_mtr_cron.sh` → **[ADD_LINK_HERE]**
- `jp_evening_heatmap.py` → **[ADD_LINK_HERE]**

---

**Outcome:** This file is both a **methodology** (W’s + Fishbone + OODA/PDCA) and a **toolkit** (userland, custom scripts, in‑kernel probes) with concrete examples and provider engagement patterns. It is designed to move from anecdote → proof → mitigation → durable fix with professional, white‑glove communication.

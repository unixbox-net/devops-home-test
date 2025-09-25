# C. You are working with a Game Studio that has received player reports from their Japanese players stating that during the evening their latency is much higher than usual, affecting their match quality. How do you go about confirming the issue and working with the game server provider to resolve it?
    Extra info:
    - i. You know that their gameservers are hosted by a third party which does not have good metrics and visibility
    - ii. You know that the gameservers are in a mix of cloud and bare metal datacenters
- What data and metrics do you need to see to be able to confirm the issue?
- What tooling would you need to be in place to help you confirm the problem?
- What debugging steps would you work through to help get a better understanding of the issue?
- How would you go about working with the gameserver provider to resolve the issue?

# JP Evening Latency — All‑in‑One Case Runbook & Troubleshooting Methodology (Expanded Commands Edition)
_A single, self‑contained Markdown that **answers the specific case questions** and documents **how I troubleshoot**. It includes the **W’s intake**, **Fishbone (Ishikawa)** model, userland commands, custom diagnostic scripts, and **in‑kernel** instrumentation (eBPF/DTrace). Built for copy‑paste execution and white‑glove collaboration with providers._

---

## Table of Contents
- [0) Ethos & Models](#0-ethos--models)
- [1) The W’s — Question‑First Intake (Full Checklist)](#1-the-ws--questionfirst-intake-full-checklist)
- [2) Access & Environment Discovery](#2-access--environment-discovery)
- [3) The Case (C) — Direct Answers (WITH PRACTICAL COMMANDS)](#3-the-case-c--direct-answers-with-practical-commands)
  - [3.1 Confirm the issue & collaborate with the provider](#31-confirm-the-issue--collaborate-with-the-provider)
  - [3.2 Third‑party with weak metrics — how to get signal](#32-thirdparty-with-weak-metrics--how-to-get-signal)
  - [3.3 Mix of cloud & bare metal — W’s for each + L2→L7 proof](#33-mix-of-cloud--bare-metal--ws-for-each--l2l7-proof)
  - [3.4 Data & metrics required to confirm the issue](#34-data--metrics-required-to-confirm-the-issue)
  - [3.5 Tooling to have in place (incl. custom craftables)](#35-tooling-to-have-in-place-incl-custom-craftables)
  - [3.6 Debug steps — Fishbone applied (with command menus)](#36-debug-steps--fishbone-applied-with-command-menus)
  - [3.7 Provider playbook — white‑glove engagement](#37-provider-playbook--whiteglove-engagement)
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

## 3) The Case (C) — Direct Answers (WITH PRACTICAL COMMANDS)

### 3.1 Confirm the issue & collaborate with the provider
**Goal:** turn player reports into measured evidence; correlate to a point in the stack; propose a reversible canary; validate fix.

#### 3.1.1 Basic hygiene (run first on every server)
```bash
# Identity, time, DNS
hostnamectl; cat /etc/hostname
date -u; timedatectl status
chronyc tracking; chronyc sources -v
cat /etc/resolv.conf; cat /etc/nsswitch.conf; getent hosts <game-hostname>

# Network identity & addressing
ip -br addr; ip -br link; ip -br -6 addr
ip route; ip -6 route; ip rule show
grep . /etc/hosts

# Name resolution checks
dig +short A <game-hostname>; dig +short AAAA <game-hostname>
dig +trace <game-hostname>; nslookup <game-hostname>
```
**Why:** Mis-set time, DNS, routes, or host files cause silent mis‑steer or TLS/auth weirdness.

#### 3.1.2 Connectivity sanity
```bash
# L3 reachability & MTU
ping -c 5 <upstream-ip>; ping -c 5 -M do -s 1472 <upstream-ip>   # path MTU check
ping6 -c 5 <upstream-v6-ip>

# Quick HTTP(s) to health endpoints (if exposed)
curl -sS -o /dev/null -w 'code=%{http_code} time_total=%{time_total}\n' https://<health-endpoint>
```
**Why:** Proves basic reachability and fragmentation issues early.

#### 3.1.3 Path & routing proof (forward & reverse)
```bash
# Paris traceroute/MTR (UDP, more game-like), forward path
mtr -u -w -z --json -c 200 <server-ip> > mtr_fwd.json

# Reverse: from the server to a JP probe (or your office / cloud VM in Tokyo)
mtr -u -w -z --json -c 200 <probe-ip> > mtr_rev.json

# Compare IPv4 vs IPv6 behavior
mtr -4 -u -w -z --json -c 200 <server-ip> > mtr_v4.json
mtr -6 -u -w -z --json -c 200 <server-v6> > mtr_v6.json
```
**Why:** Many evening issues are peering/IX congestion or detours; first bad hop + ASN gives provider‑actionable evidence.

#### 3.1.4 Server health quicklook
```bash
# CPU, load, steal (cloud), interrupts, softirqs
uptime; mpstat -P ALL 1 5
cat /proc/softirqs | sed -n '1,50p'

# Memory/hugepages; pressure (if available)
free -h; grep -H . /sys/kernel/mm/transparent_hugepage/*
cat /proc/pressure/{cpu,io,memory} 2>/dev/null || true

# NIC stats & queues
for IF in $(ls /sys/class/net | grep -E 'eth|ens|eno|enp'); do
  echo "=== $IF ==="
  ethtool -S $IF | egrep 'rx_dropped|tx_dropped|rx_no_buffer|rx_missed|fifo|errors' || true
  ethtool -k $IF | egrep 'gro|gso|tso|lro|rxhash'
  ethtool -l $IF 2>/dev/null | sed -n '1,80p' || true
done

# qdisc / backlog
tc -s qdisc show dev <uplink-iface> | sed -n '1,80p'
```
**Why:** Softirq backlogs, ring overflows, and qdisc queues directly manifest as jitter/loss.

#### 3.1.5 Socket & flow observations
```bash
# Top UDP listeners and their queues
ss -u -lpn | head -50
ss -u -npi | sed -n '1,200p'   # look for send/recv queue sizes

# IP stack counters
nstat -az | egrep 'InErrs|IpReasmFails|UdpInErrors|TcpRetransSegs|RcvbufErrors|SndbufErrors'
```
**Why:** Confirms if the problem is inside the host (buffering, drops) vs. outside (path).

#### 3.1.6 Short targeted captures
```bash
# Minimal rotating capture (20 MB) on the game port
tcpdump -ni <uplink-iface> udp port <GAME_PORT> -C 20 -W 4 -w game.cap &

# Quick loss/jitter feel using tshark stats (if installed)
tshark -i <uplink-iface> -f "udp port <GAME_PORT>" -q -z io,stat,5
```
**Why:** Packet timing and loss visible without drowning in pcap.

#### 3.1.7 Synthetic throughput & jitter
```bash
# UDP jitter/bw toward server (from a JP probe)
iperf3 -u -b 50M -t 30 -c <server-ip> --json > iperf_to_server.json
# Reverse (server acts as client if allowed)
iperf3 -u -b 50M -t 30 -c <probe-ip> --json > iperf_to_probe.json
```
**Why:** Validate sustained bandwidth and jitter headroom during evening window.

#### 3.1.8 Collaborate with provider (practical flow)
- Send the **one‑pager** with graphs/heatmaps + **mtr fwd/rev** JSON.  
- Include **safe read‑only command pack** (see §6.1) so they can reproduce counters/screenshots.  
- Ask for **edge/TOR/IX** utilization/drops and transient **BGP/scrubbing** changes over **19:00–24:00 JST**.  
- Propose a **canary**: route 10–20% JP traffic via alternate transit/POP or bypass scrubbing for the game UDP ports; compare p95 RTT/jitter/loss.

---

### 3.2 Third‑party with weak metrics — how to get signal
- **Players/support signals**: export ticket timestamps and categories; graph vs JST hour.  
- **Client telemetry (RUM)**: embed RTT/jitter/loss histograms with labels (**ISP/ASN**, **IPv4/6**, **serverID**).  
- **Self‑run probes**: Tokyo/Osaka VPS across NTT/KDDI/SoftBank; cron `mtr` and `iperf3 -u` JSON; hash artifacts.  
- **If they can’t export**: provide the **command pack** (read‑only), request raw outputs + SHA256SUMS.

---

### 3.3 Mix of cloud & bare metal — W’s for each + L2→L7 proof
- **Cloud**: check **CPU steal/throttle**, vNIC offloads (ENA/SR‑IOV), AZ placement, regional DDoS layer; try **Global Accelerator/Anycast** or **alternate transit** canary.  
- **Bare metal**: confirm NIC driver/firmware, **IRQ/RSS/XPS** layout, **NUMA** pinning, TOR uplink headroom, IX peering status.  
- **L2→L7**: MTU/frag; UDP/TCP path loss/jitter; socket queues/pacing; app tick/frame timing; DNS geo/TTL (v4 vs v6).

---

### 3.4 Data & metrics required to confirm the issue
- **Player RUM**: RTT, jitter, loss histograms with **ISP/ASN**, **IPv4/6**, **serverID**, city/device; 5–10‑min bins; **JST** timestamps.  
- **Server/Host**: CPU user/sys/**steal**, run queue; **softirq/IRQ** rates; NIC `ethtool -S` drops/rings; **qdisc** backlog; per‑socket RTT/loss; **PPS/BPS** per process; **time sync**.  
- **Network/Path**: Paris MTR fwd/rev; first bad hop/ASN/IX; **IPv4 vs IPv6** deltas; **edge/TOR/IX** utilization/drops; **BGP/scrubbing** logs.  
- **Business**: abandon/reconnect/complaint rates correlated to the evening window.

---

### 3.5 Tooling to have in place (incl. custom craftables)
- **Off‑the‑shelf**: Prometheus/Grafana, OTel, ELK/Loki; RIPE/ThousandEyes/Catchpoint or DIY probes; node_exporter, snmp_exporter.  
- **Custom**: `udp_rtt_buckets.bpf`, `nicq_watch.bpf`, `tick_drift_probe.bpf`, `paris_mtr_cron.sh`. *(Drop repo links in §8.3.)*

---

### 3.6 Debug steps — Fishbone applied (with command menus)
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
**Network/Peering — commands:**  
```bash
mtr -u -w -z --json -c 200 <target>
traceroute -U -p <GAME_PORT> <target>
ip -s link show <uplink>; ethtool -S <uplink>
```
**Host/Kernel/NIC — commands:**  
```bash
mpstat -P ALL 1 5; cat /proc/softirqs | sed -n '1,50p'
ethtool -k <uplink>; ethtool -l <uplink>; tc -s qdisc show dev <uplink>
ss -u -npi | sed -n '1,200p'
```
**Capacity/Matchmaking — actions:** check pool utilization, serverID distribution, and matchmaking policy weights.  
**Application/Tick — commands:** bpftrace uprobes around tick loop; `perf top/record`; flamegraphs.  
**DNS/Geo/Policy — commands:**  
```bash
dig +short A <game-hostname>; dig +short AAAA <game-hostname>
dig @<resolver> <game-hostname> +nsid
```
**Change/Config — actions:** 72‑hour change audit; `git log` in infra repos; package diffs.  
**DDoS/Security — actions:** request scrubbing logs; test with/without scrubbing; closest scrubbing POP.

---

### 3.7 Provider playbook — white‑glove engagement
- **Modes**: (1) We run; (2) They run our pack; (3) Screen‑share we drive.  
- **Send**: one‑pager (impact window), RUM heatmaps, host overlays, MTR fwd/rev with ASN callouts.  
- **Ask (48h)**: edge/TOR/IX counters; peering matrix; BGP/scrubbing notes; placement/noisy‑neighbor; **A/B routing** canary approval.  
- **Validate**: compare p95 RTT/jitter/loss over two evenings; promote winning path; lock peering/tuning; publish concise player status.

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

**Outcome:** This single document **answers the case prompts** with accessible, copy‑paste commands, while preserving a rigorous method (W’s + Fishbone + OODA/PDCA). It enables fast proof → mitigation → durable fix with professional, white‑glove collaboration.

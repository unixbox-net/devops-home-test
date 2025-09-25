### C. You are working with a Game Studio that has received player reports from their Japanese players stating that during the evening their latency is much higher than usual, affecting their match quality. How do you go about confirming the issue and working with the game server provider to resolve it?

-  Extra info:
    -  i. You know that their gameservers are hosted by a third party which does not have good metrics and visibility
    - ii. You know that the gameservers are in a mix of cloud and bare metal datacenters
      
- What data and metrics do you need to see to be able to confirm the issue?
- What tooling would you need to be in place to help you confirm the problem?
- What debugging steps would you work through to help get a better understanding of the issue?
- How would you go about working with the gameserver provider to resolve the issue?



# Anthony’s Troubleshooting Methodology

*A repeatable, evidence‑driven framework that blends surveillance‑grade audit discipline, white‑glove customer care, and deep kernel instrumentation (eBPF/DTrace/custom in‑kernel tools) to find root cause rapidly and communicate it clearly.*

---

## Core Principles

* **Patient, Relentless, Precise:** Treat every system as auditable. Assume logs/configs contain the answer; dig until they do.
* **Minimize Guesswork:** Instrument first; hypothesize from data, not anecdotes.
* **Small, Safe Experiments:** Change one thing at a time; measure deltas.
* **Bias for Root Cause:** Fix systemic causes, not symptoms.
* **Communicate Like a Partner:** White‑glove updates tailored to the audience; never leave stakeholders guessing.

---

## Reference Models I Operationalize

* **OODA Loop (Observe → Orient → Decide → Act):** Drives fast cycles under uncertainty.
* **PDCA (Plan → Do → Check → Act):** Ensures fixes are verified and standardized.
* **Kepner–Tregoe (KT):** Structured problem analysis & decision‑making for complex cases.
* **SRE Signals (RED/USE):** Requests, Errors, Duration (user view); Utilization, Saturation, Errors (resource view).

---

## End‑to‑End Workflow

### 1) Intake & Problem Framing (Observe)

* Capture **who/what/when/where**; pin exact **time windows** and **blast radius**.
* Define **customer impact** (SLO/SLA breach, business priority) and **hypotheses** to test.
* Start an **evidence log** (immutable notes, timestamps, commands run, hashes of artifacts).

### 2) Baseline & Scope Control (Orient)

* Establish **known‑good baselines** (latency, throughput, CPU, memory, error rates, config checksums).
* Segment by **cohorts** (region/ISP/version/host/AZ) to narrow the surface area.
* Quick health snapshot: `uptime`, `dmesg -T`, `journalctl --since`, service status, SLO dashboards.

### 3) Audit & Compliance Sweep (Orient)

* **Config integrity:** diff against gold standards; verify permissions/ownership/ACLs; check OS hardening.
* **Change review:** last 24–72h deployments, patching, infra changes, security policy changes.
* **Artifact custody:** ensure logs/configs are collected, signed, and preserved for chain of custody.

### 4) Instrumentation Plan (Decide)

* Choose lowest‑risk, highest‑signal probes. Start userland, escalate to kernel only as needed.
* Define **success metrics** (what will confirm/refute each hypothesis) and **roll‑back plan**.

### 5) Evidence Collection (Do)

* **Userland telemetry:** `sar`, `vmstat`, `iostat`, `pidstat`, `perf stat`, `strace/ltrace`, `tcpdump`, app logs.
* **Kernel‑level tracing (strength):**

  * **eBPF/bpftrace/BCC:** function entry/exit, kprobes/uprobes, histograms of latency, per‑PID I/O/CPU/net.
  * **DTrace (where applicable):** systemic tracing across syscalls, scheduler, network, file I/O.
  * **Custom in‑kernel tools:** targeted probes for suspicious functions or code paths.
* **Network path:** MTR/Paris traceroute, QUIC/TCP stats, packet captures with filters; verify MTU/DSCP.
* **Config & state snapshots:** checksumd tarballs of `/etc`, unit files, sysctls, container manifests.

### 6) Analysis & Hypothesis Testing (Check)

* Correlate **time‑aligned** metrics: app logs ↔ kernel traces ↔ network captures ↔ infra events.
* Apply **RED/USE** lenses to isolate bottlenecks; use **KT** to contrast plausible causes.
* Reproduce with **small, controlled experiments**; quantify improvement or regression.

### 7) Remediation & Risk Management (Act)

* Prioritize **low‑risk, high‑impact** mitigations first.
* Implement fixes behind **feature flags/safeguards** where possible.
* Validate against SLOs; monitor for side effects; keep a **backout** ready.

### 8) Communication & White‑Glove Care (Continuous)

* **Cadenced updates** (scope → evidence → status → next steps → ETA of next update).
* Share **visuals** (graphs, timelines, flame graphs, sequence diagrams) rather than raw log walls.
* Maintain empathy; translate technical findings into **business impact** and **risk** for decision‑makers.

### 9) Escalation Package (When Needed)

* **One‑page summary:** problem statement, impact, timeline, top hypotheses, current status.
* **Evidence annex:** curated logs, kernel traces, pcap extracts, repro steps, screenshots.
* **Specific asks:** data needed, access, config changes, routing/infra tests; define **success criteria**.

### 10) Post‑Incident & Hardening

* Root cause narrative (5 Whys / KT). Corrective & preventive actions (CAPA). Update runbooks.
* Add new **probes/dashboards/alerts**. Automate recurrent checks. Train the team.

---

## Tooling Taxonomy (My Default Kit)

### Userland

* Observability: Prometheus/Grafana, Loki/ELK, OpenTelemetry.
* Perf & OS: `perf`, `pidstat`, `sar`, `vmstat`, `iostat`, `numastat`, `free`, `ps/top/htop`.
* Networking: `mtr`, `traceroute`/Paris, `ss`, `tcpdump`, `nstat`, `ethtool`, `tc`, `iperf3`.

### Kernelland (Differentiator)

* **eBPF/BCC/bpftrace:** `runqlat`, `biolatency`, custom kprobe/tracepoint scripts.
* **DTrace/SystemTap:** systemic probes (where supported).
* **Custom in‑kernel modules/programs:** precision tracing of suspect subsystems/functions.

### Audit/Compliance

* Config baselining: `git`‑tracked `/etc`; CIS checks; file integrity (AIDE/Tripwire).
* Change governance: deployment manifests, signed artifacts, SBOMs.

---

## Evidence Standards & Data Hygiene

* **Time sync** (NTP/chrony/PTP); record timezone.
* **Hash** every artifact; store with metadata (host, service, time window).
* Prefer **structured logs** (JSON) and **machine‑readable** exports (pcap, perf.data, bpftrace histograms).
* Redact PII/keys; maintain access logs for sensitive data.

---

## Communication Templates

### Stakeholder Update (Concise)

* **Status:** Investigating / Mitigating / Monitoring
* **Impact:** Who is affected; SLO/SLA status
* **Findings:** Top 1–2 data‑backed observations (graphs attached)
* **Next Steps:** What we’re testing next + timing for next update

### Escalation Request (External Provider)

* **Problem Statement:** <1–2 sentences with metrics and time range>
* **Evidence:** bullet list with links to artifacts
* **Specific Asks:** data, tests, changes requested; **success criteria**
* **Contact/Bridge:** comms channel, availability window

---

## Checklists

### Fast Triage (5–10 minutes)

* [ ] Confirm time window & impact
* [ ] Grab top dashboards & recent deploys
* [ ] Snapshot dmesg/journal/service states
* [ ] Start evidence log & collection

### Deep Dive (30–90 minutes)

* [ ] Baseline vs current deltas
* [ ] Kernel/userland probes running
* [ ] Network path verified (MTU, loss, detours)
* [ ] Hypotheses ranked with test plans

### Verify & Close

* [ ] Fix validated vs SLOs
* [ ] Regression monitors in place
* [ ] Post‑incident notes + CAPA filed
* [ ] Runbooks updated; automation pull requests opened

---

## Operating Rules I Enforce

* **Don’t escalate noise.** If I can instrument the exact failing function, I will.
* **No heroics without evidence.** Every risky action needs reversible steps and metrics.
* **Prefer determinism.** Reproducible tests, pinned versions, controlled environments.
* **Make it teachable.** Every solved case becomes a simplified runbook and a reusable probe.

---

## Outcome

This methodology yields faster time‑to‑root‑cause, calmer stakeholders, and escalations that drive action because they are backed by precise, kernel‑level evidence formatted for decision‑makers.

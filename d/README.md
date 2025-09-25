# D) SEV2 Incident Playbook — 25% Drop in HTTP 200s for Player Authentication
_Comprehensive on‑call runbook aligned to **Google SRE** and the **SRE Workbook**. Includes ICS roles, SEV2 timelines, golden signals, Fishbone troubleshooting, concrete tests (with expected outcomes), mitigation/rollback, comms cadence, postmortem skeleton, printable checklists — and a full **References & Further Reading** section with source links._

> **Scenario**: You are paged for a **25% drop in HTTP 200 responses** on the **player authentication** endpoint of the **main backend API**. This is a **SEV2** (major degradation, not total outage). You will declare, diagnose, mitigate, communicate, and close.

---

## Table of Contents
- [Foreword](#foreword)
- [0) Scope, Assumptions, and Definitions](#0-scope-assumptions-and-definitions)
- [1) Incident Roles & Structure (ICS-style)](#1-incident-roles--structure-ics-style)
- [2) SEV2 Timeline — Minute-by-Minute](#2-sev2-timeline--minute-by-minute)
- [3) Fast Identification — Confirm It’s an API/Web Incident](#3-fast-identification--confirm-its-an-apiweb-incident)
- [4) Golden Signals, SLOs, and Burn-Rate Alarms](#4-golden-signals-slos-and-burn-rate-alarms)
- [5) Structured Diagnostics — Fishbone with Command Menus](#5-structured-diagnostics--fishbone-with-command-menus)
- [6) Mitigation Menu (Safe, Reversible, Tracked)](#6-mitigation-menu-safe-reversible-tracked)
- [7) Proving Resolution, Exit Criteria, and Rollback of Workarounds](#7-proving-resolution-exit-criteria-and-rollback-of-workarounds)
- [8) Communication Cadence & Stakeholder Messaging](#8-communication-cadence--stakeholder-messaging)
- [9) Postmortem (Blameless) & CAPA Plan](#9-postmortem-blameless--capa-plan)
- [Appendix A — Query/Command Library](#appendix-a--querycommand-library)
- [Appendix B — Templates & Checklists](#appendix-b--templates--checklists)
- [Appendix C — Example Incident State Doc](#appendix-c--example-incident-state-doc)
- [References & Further Reading](#references--further-reading)

---

## Foreword
This playbook synthesizes the **Google SRE** books’ guidance on: **golden signals**, **incident response**, **managing incidents**, **postmortems**, and **configuration/canarying**. It uses ICS‑style roles (IC/OL/CL/Scribe) and **SEV2** operating parameters (major impact, partial functionality). Links to primary sources are provided at the end of this file.

---

## 0) Scope, Assumptions, and Definitions
**Impact**: 25% reduction in HTTP 200s for `/auth` (or `/token`) across one or more regions/POPs.  
**Severity**: **SEV2** — significant user impact; service degraded but not totally unavailable.  
**Objective**: Minimize user harm, restore success rate to SLO target, protect error budget, and produce a durable fix.

**Assumptions** (state explicitly in the incident doc):
- **Observability**: Metrics (Prometheus/Cloud), Logs (structured; queryable), Traces (OTel), Exemplar links.
- **Monitoring**: SLOs, burn‑rate alerts, dashboards for service & dependencies (IdP/DB/cache/CDN/WAF/DNS).
- **Controls**: Feature flags, staged rollouts, config management, fast rollback, per‑region disables.
- **Dependencies**: IdP/OIDC, DB, session/cache, rate limiter, WAF/CDN, DNS/TLS/KMS, NTP/PTP.
- **Access**: On‑call has production read access, runbooks, and pager escalation paths to providers (IdP/CDN).

**Definition of Done (DoD)** (preview; details in §7):
- 200‑rate restored to baseline; 4xx/5xx back to normal; p95 latency stable.  
- Workarounds rolled back or stabilized; action items assigned; PM scheduled.

---

## 1) Incident Roles & Structure (ICS-style)
Assign immediately (or confirm):
- **Incident Commander (IC)** — owns severity/scope, approves mitigations, sets cadence.
- **Operations Lead (OL)** — drives technical diagnosis/mitigation; forms workstreams.
- **Communications Lead (CL)** — stakeholder/internal/external comms; status page drafts.
- **Scribe** — timeline, decisions, artifacts (graphs, logs, SHA256SUMS), change IDs.
- **Liaisons** — IdP/CDN/DB owners; Customer Support; Partner on‑calls.

**Workstreams** (OL assigns leads per stream):
1. **Edge/WAF/CDN/Network**  
2. **Auth Service / Application**  
3. **IdP / External Identity**  
4. **DB / Cache / Rate Limiter**  
5. **Change/Config / Release / Feature Flags**

---

## 2) SEV2 Timeline — Minute-by-Minute
> Use this as the scribe’s skeleton; adjust times to your environment’s SLAs.

**T+00–05 (Declare & Stabilize)**
- Ack page, declare **SEV2**, open incident room/doc, assign IC/OL/CL/Scribe.  
- IC sets **update cadence** (every **20 min**).  
- OL triggers **Section 3** fast identification.  
- Apply **safe, reversible stabilization** if obvious (remove canary; disable suspect flag).

**T+05–15 (Bound & Slice)**
- Determine scope by **region/POP**, **platform**, **client version**, **feature cohort**.  
- If localized, **shed or shift traffic** away from the bad slice.  
- Start **evidence log** (commands, outputs, hashes).

**T+15–30 (Hypothesize & Test)**
- Choose Fishbone branches (Network/Edge vs IdP vs DB/Cache vs App vs Policy vs Change).  
- Run **Appendix A** commands/queries; capture artifacts.

**T+30–45 (Mitigate & Measure)**
- Implement targeted mitigations from §6 with change IDs.  
- Validate with golden signals and synthetic checks; keep a control cohort for comparison.

**T+45–60 (Stabilize & Decide)**
- If metrics normalize: plan rollback of temporary relaxations; choose CAPA path.  
- If not: escalate to **provider on‑calls**; consider region failover; widen team.

**T+60+ (Sustain & Monitor)**
- Maintain cadence; monitor for regression; prepare **executive summary**.  
- IC decides incident closure when §7 criteria met; CL prepares stakeholder wrap‑up.

---

## 3) Fast Identification — Confirm It’s an API/Web Incident
> **Goal: 10–15 minutes** to confirm the failure mode and where it sits (edge vs app vs dependency).

### 3.1 Basic Hygiene (run on an auth pod/VM)
```bash
# Identity, time, DNS
hostnamectl; date -u; timedatectl
chronyc tracking; chronyc sources -v
cat /etc/resolv.conf; getent hosts idp.example.com api.example.com

# Addressing & routes
ip -br addr; ip route; ss -s

# TLS sanity (expiry/chain)
echo | openssl s_client -connect api.example.com:443 -servername api.example.com 2>/dev/null \
  | openssl x509 -noout -dates -issuer -subject
```
**Expected**: UTC synced; names resolve; cert valid and not expiring today.

### 3.2 API/L7 Health (prove HTTP issue quickly)
```bash
# From an edge POP or bastion near players
curl -sS -o /dev/null -w 'code=%{http_code} t_conn=%{time_connect} t_ssl=%{time_appconnect} t_total=%{time_total}\n' \
  https://api.example.com/auth/health
```
**Expected**: **200** and stable **t_total**. Non‑200 → deeper check.

### 3.3 IdP reachability & JWKS
```bash
curl -sS https://idp.example.com/.well-known/openid-configuration | jq '.issuer,.jwks_uri'
curl -sS https://idp.example.com/.well-known/jwks.json | jq '.keys[].kid' | sort -u
```
**Expected**: issuer & JWKS reachable; at least one **kid**.

### 3.4 Code Mix & Latency Snapshot (dashboards)
- **HTTP code mix** last 30/60 min (2xx/4xx/5xx).  
- **p50/p95 latency** trends; upstream span errors (IdP/DB/cache).  
- **Breakdown by slice**: region/POP, platform, client version, feature cohort.

**Expected**: Identify whether it’s **4xx‑heavy** (policy/time/jwks), **5xx‑heavy** (backend), or **traffic routing**.

### 3.5 Network/Edge quick wins
```bash
mtr -u -w -z -c 200 api.example.com
mtr -u -w -z -c 200 idp.example.com
grep -Ei 'deny|blocked|ratelimit|bot' /var/log/waf/*.log | tail -n 200
```
**Expected**: minimal loss; WAF not blocking auth paths.

---

## 4) Golden Signals, SLOs, and Burn-Rate Alarms
**Healthy** auth: stable **2xx rate** at/near SLO; **401/403** within normal band; **5xx** ~0; **p95 latency** steady; dependency **saturation** below redlines.

**Starter PromQL** (adapt labels):
```promql
# Success rate: 2xx / total
sum(rate(http_requests_total{svc="auth",code=~"2.."}[5m]))
/ ignoring(code) sum(rate(http_requests_total{svc="auth"}[5m]))

# Code mix by region
sum(rate(http_requests_total{svc="auth"}[5m])) by (region,code)

# Upstream error ratio (IdP/DB/cache)
sum(rate(http_client_errors_total{client="auth"}[5m])) by (upstream)
/ sum(rate(http_client_requests_total{client="auth"}[5m])) by (upstream)

# Latency p95 by region
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{svc="auth"}[5m])) by (le,region))
```

**Logs (LogQL‑style)**:
```
{svc="auth"} |= "/auth" | json | stats count() by (status, region, error, upstream)
```

**Traces (OTel)**: filter `service.name="auth"`, `span.kind=client`, `peer.service in ("idp","db","cache")`, duration > p95.

**Burn‑rate policy**: implement **multi‑window, multi‑burn‑rate** alerting (short & long windows) as per the SRE Workbook, Chapter “Alerting on SLOs.”

---

## 5) Structured Diagnostics — Fishbone with Command Menus
```
     Network/Edge/Peering ──┐   Capacity/Rate‑limit ─┐   DNS/TLS/Policy ──────┐
     (CDN, WAF, POP, loss)   │   (pools/queues)      │   (WAF, bot, certs)    │
                             │                        │                         │
     Host/Runtime/Kernel ────┤   Application/Auth ───┤   Change/Config ───────┤
     (CPU, GC, sockets)      │   (logic, flags)      │   (deploy, rollout)    │
                             │                        │                         │
     IdP/DB/Cache ───────────┘   DDoS/Security ──────┘   Time/Keys/JWKS ──────┘
```

### A) **4xx (401/403) spike**
**Likely**: clock skew; JWKS/key rotation; issuer/audience mismatch; WAF/bot rule; feature flag gating.  
**Checks**
```bash
date -u; chronyc tracking
curl -sS https://idp.example.com/.well-known/jwks.json | jq '.keys[].kid' | sort -u
grep -Ei 'kid|jwks|aud|iss' /var/log/auth/*.log | tail -n 200
```
**Expected**: time in sync; token `kid` exists; no `kid not found`/`aud invalid` errors.  
**Mitigate**: refresh JWKS cache; temporarily extend skew; roll back auth config; bypass specific WAF rule.

### B) **5xx spike**
**Likely**: IdP/DB/cache errors; pool exhaustion; timeouts.  
**Checks**
```bash
uptime; mpstat -P ALL 1 5; free -h
cat /proc/pressure/{cpu,io,memory} 2>/dev/null || true
ss -tnp | head -80
nstat -az | egrep 'TcpRetransSegs|InErrs|RcvbufErrors|SndbufErrors'
grep -Ei 'pool|timeout|maxconn' /var/log/auth/*.log | tail -n 200
```
**Mitigate**: add replicas; bump connection pools; modestly raise IdP/DB timeouts; backoff retries; scale cache; rollback latest build.

### C) **Latency ↑ then errors**
**Likely**: slow upstream; DNS/OCSP; POP jitter.  
**Checks**
```bash
mtr -u -w -z -c 200 idp.example.com
dig +trace idp.example.com
echo | openssl s_client -connect idp.example.com:443 -servername idp.example.com 2>/dev/null \
  | openssl x509 -noout -dates
```
**Mitigate**: pin to healthy IdP region; bump client timeout slightly; circuit‑break unhealthy upstreams.

### D) **Traffic anomaly**
**Likely**: CDN rule, DNS weight shift, app throttling.  
**Checks**
```bash
grep -E 'pop=|denied|ratelimit' /var/log/waf/*.log | tail -n 200
dig api.example.com +short; dig api.example.com TXT
```
**Mitigate**: restore DNS weights; revert CDN/WAF rule; unthrottle client.

### E) **Host/Kernel/NIC saturation (rare for auth, still check)**
```bash
cat /proc/softirqs | sed -n '1,60p'
tc -s qdisc show dev <uplink> | sed -n '1,60p'
ethtool -S <uplink> | egrep 'rx_dropped|tx_dropped|fifo|missed'
```
**Mitigate**: raise pod CPU/mem; GC tuning; increase backlog; spread IRQs; enable fq/fq_codel.

---

## 6) Mitigation Menu (Safe, Reversible, Tracked)
- **Traffic shaping**: remove canary; shift off bad region/POP; pin to healthy IdP region.  
- **Config rollback**: revert auth config/feature flag; restore last‑known‑good.  
- **Keys & Time**: force JWKS refresh; temporarily extend clock skew; pause key rotation; fix NTP.  
- **Capacity**: scale replicas; bump DB/cache pool sizes; warm caches; adjust autoscaling ceilings.  
- **Policy**: temporarily relax/bypass **WAF/bot** rules verified to block legit auth.  
- **Timeouts/retries**: raise client timeout slightly; enable retries (with jitter); circuit‑break failing backends.

> **Scribe must record**: change ID, owner, timestamp, scope, rollback steps, and result for each mitigation.

---

## 7) Proving Resolution, Exit Criteria, and Rollback of Workarounds
**Exit Criteria** (all true for ≥ 60–120 min):
- **2xx success rate** back to baseline; **4xx/5xx** normalized.  
- **p95 latency** stable; **saturation** under thresholds.  
- No regression during rollback of temporary relaxations (do in reverse order).

**After normalization**:
- Remove bypasses/rule relaxations, confirm key rotation resumed, restore autoscaling defaults, unpin traffic if safe.

---

## 8) Communication Cadence & Stakeholder Messaging
**Cadence**: **every 20 minutes** until contained, **every 30–60 minutes** afterward.  
**Audiences**: Engineering, CS/Support, Execs, (optionally) Status Page.

**Update Template**
```
[HH:MMZ] SEV2 — 25% drop in HTTP 200s on /auth since HH:MMZ.
Scope: region=tokyo-1 (JP-heavy), platform=mobile vX.Y, cohort=flag 'new_login_flow'.
Findings: 5xx to IdP up (502/504); p95 latency ↑; no WAF blocks.
Actions: Disabled 'new_login_flow' canary; pinned IdP to tokyo-2; scaled auth +3.
Requests: IdP on-call check tokyo-1; CDN share POP error logs.
Next Update: HH:MMZ (+20m). IC=<name> OL=<name> CL=<name> Scribe=<name>.
```

**Final Executive Summary (on closure)**: What happened; user impact; timeline; cause; fix; follow‑ups.

---

## 9) Postmortem (Blameless) & CAPA Plan
- **When**: within **72 hours**.  
- **Contents**: Summary, Impact metrics, Timeline (UTC/JST), Contributing factors, Detection & response, What went well/poorly, Action items with owners/dates, CAPA (prevention/mitigation), Links to artifacts/dashboards.  
- **Distribution**: Engineering leadership, CS, affected partners; stored in PM repo.

---

## Appendix A — Query/Command Library

### A.1 PromQL
```promql
# Success rate
sum(rate(http_requests_total{svc="auth",code=~"2.."}[5m])) 
/ ignoring(code) sum(rate(http_requests_total{svc="auth"}[5m]))
# Code mix by region
sum(rate(http_requests_total{svc="auth"}[5m])) by (region,code)
# Upstream error ratio
sum(rate(http_client_errors_total{client="auth"}[5m])) by (upstream)
/ sum(rate(http_client_requests_total{client="auth"}[5m])) by (upstream)
# Latency p95 by region
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{svc="auth"}[5m])) by (le,region))
# Burn rate (illustrative)
sum(rate(http_requests_total{svc="auth",code!~"2.."}[5m]))
/ sum(rate(http_requests_total{svc="auth"}[5m]))
```

### A.2 Logs (LogQL/Pseudo-SQL)
```
{svc="auth"} |= "/auth" | json | stats count() by (status, region, error, upstream)
{svc="edge"} |= "deny" |= "/auth" | json | stats count() by (pop, rule_id)
```

### A.3 Traces (OTel search hints)
- `service.name="auth"` and `span.kind=client`  
- `peer.service in ("idp","db","cache")`  
- `duration > p95` and `status.code != OK`

### A.4 Linux commands (copy/paste)
```bash
# Hygiene
hostnamectl; date -u; timedatectl
chronyc tracking; chronyc sources -v
cat /etc/resolv.conf; getent hosts idp.example.com api.example.com
ip -br addr; ip route; ss -s

# TLS
echo | openssl s_client -connect api.example.com:443 -servername api.example.com 2>/dev/null \
  | openssl x509 -noout -dates -issuer -subject

# Edge & path
mtr -u -w -z -c 200 api.example.com
mtr -u -w -z -c 200 idp.example.com

# WAF/CDN denies
grep -Ei 'deny|blocked|ratelimit|bot' /var/log/waf/*.log | tail -n 200

# Host health
uptime; mpstat -P ALL 1 5; free -h
cat /proc/pressure/{cpu,io,memory} 2>/dev/null || true
ss -tnp | head -80
nstat -az | egrep 'TcpRetransSegs|InErrs|RcvbufErrors|SndbufErrors'

# IdP/JWKS
curl -sS https://idp.example.com/.well-known/openid-configuration | jq '.issuer,.jwks_uri'
curl -sS https://idp.example.com/.well-known/jwks.json | jq '.keys[].kid' | sort -u
```

### A.5 Kubernetes (if applicable)
```bash
kubectl get deploy auth -o wide
kubectl describe deploy auth | sed -n '1,120p'
kubectl rollout history deploy/auth
kubectl rollout undo deploy/auth --to-revision=<N>
kubectl logs deploy/auth --since=30m | tail -n 200
```

---

## Appendix B — Templates & Checklists

### B.1 Incident Declaration (SEV2)
- Time (UTC/JST), IC/OL/CL/Scribe assigned
- Impact statement (percent, endpoints, regions)
- SLO/SLA affected; burn‑rate status
- Known changes in last 60–120 min
- Initial mitigation (if any) and rollback plan
- Next update time

### B.2 Change/Mitigation Record
```
[UTC] ChangeID=<id> | Owner=<name> | Action=<what> | Scope=<where> | Rollback=<steps> | Result=<metrics delta> | Artifact=<link>
```

### B.3 Evidence Log (printable)
```
UTC/JST | Actor | Command/Query | Output summary | Artifact path + SHA256 | Next step
```

### B.4 Status Update Template
```
[HH:MMZ] SEV2 — 25% 2xx drop on /auth (since HH:MMZ).
Scope: <regions>, <platforms>, <cohorts>.
Findings: <concise facts>.
Actions: <mitigations applied>.
Requests: <asks to providers/teams>.
Next Update: HH:MMZ (+20m). IC=<name> OL=<name> CL=<name> Scribe=<name>.
```

---

## Appendix C — Example Incident State Doc
**Title**: SEV2 — 25% drop in HTTP 200s on /auth — YYYY‑MM‑DD  
**IC**: … **OL**: … **CL**: … **Scribe**: …  
**Start**: … **Current**: … **Next update**: …

**Impact**: 25% reduction in 200s; regions affected (tokyo‑1>osaka‑1), mobile vX.Y cohort.  
**User‑visible**: Increased login failures/retries; slower sign‑in.

**Hypotheses & Tests**:
- 5xx to IdP up — verify via PromQL & traces (Appendix A) → **True/False**
- 401 spike — verify JWKS/clock skew → **True/False**
- WAF denies on /auth — check logs → **True/False**
- DB pool exhaustion — check logs/pool → **True/False**

**Mitigations & Results**:
- Disabled canary flag `new_login_flow` — **+10% 200s in tokyo‑1**  
- Pinned IdP region to tokyo‑2 — **p95 latency −40%**  
- Scaled auth +3 replicas — **queue depth normalized**

**Decision Log**: IC approvals + timestamps.  
**Exit Criteria**: §7.  
**Closure Summary**: …  
**Action Items**: owners + due dates.

---

## References & Further Reading
- **Site Reliability Engineering (SRE) Book** — *Monitoring Distributed Systems*, *Practical Alerting*, *Managing Incidents*, *Postmortem Culture*, et al.  
  https://sre.google/books/  
  Monitoring chapter: https://sre.google/sre-book/monitoring-distributed-systems/  
  Emergency response chapter: https://sre.google/sre-book/emergency-response/  
  Postmortem culture chapter: https://sre.google/sre-book/postmortem-culture/

- **The Site Reliability Workbook** — *Incident Response*, *Alerting on SLOs*, *On‑Call*, *Canarying Releases*, etc.  
  ToC: https://sre.google/workbook/table-of-contents/  
  Incident Response: https://sre.google/workbook/incident-response/  
  Alerting on SLOs (multi‑window, multi‑burn‑rate): https://sre.google/workbook/alerting-on-slos/

- **Incident Management Guide (IMAG, PDF)** — ICS roles & “3Cs” (coordinate, communicate, control).  
  https://static.googleusercontent.com/media/sre.google/en//static/pdf/IncidentManagementGuide.pdf

- **Building Secure & Reliable Systems (BSRS)** — security × reliability practices.  
  Overview: https://sre.google/books/  
  O’Reilly page: https://www.oreilly.com/library/view/building-secure-and/9781492083115/

- **Supplemental**  
  Google Cloud: Fearless shared postmortems: https://cloud.google.com/blog/products/gcp/fearless-shared-postmortems-cre-life-lessons  
  Grafana: Multi‑window, multi‑burn‑rate implementation notes: https://grafana.com/blog/2025/02/28/how-to-implement-multi-window-multi-burn-rate-alerts-with-grafana-cloud/  
  SLO Generator discussion referencing Workbook #6: https://github.com/google/slo-generator/discussions/376

---

**End of Playbook.**

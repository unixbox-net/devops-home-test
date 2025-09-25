# D) On‑Call Runbook — 25% Drop in HTTP 200s for Player Authentication
_Production incident playbook aligned to Google SRE guidance (golden signals, incident roles, blameless postmortems). Includes Fishbone troubleshooting, timeline, role assignments, concrete commands/queries, tests with expected results, and provider/partner coordination._

> **Scenario**: You are paged for a **25% drop in HTTP 200 responses** on the **player authentication** endpoint of the **main backend API**. You own the incident from declaration → mitigation → root cause → close.

---

## Table of Contents
- [0) Assumptions & Supporting Systems](#0-assumptions--supporting-systems)
- [1) Roles & Incident Structure (ICS‑style)](#1-roles--incident-structure-icsstyle)
- [2) Timeline & Priorities (First Hour Guide)](#2-timeline--priorities-first-hour-guide)
- [3) Fast Identification — It’s an API/Web Problem: Prove It](#3-fast-identification--its-an-apiweb-problem-prove-it)
- [4) Golden Signals & Dashboards (What “Good” Looks Like)](#4-golden-signals--dashboards-what-good-looks-like)
- [5) Structured Diagnostics — Fishbone with Command Menus](#5-structured-diagnostics--fishbone-with-command-menus)
- [6) Mitigation Menu (Safe & Reversible)](#6-mitigation-menu-safe--reversible)
- [7) Proving Resolution & Exit Criteria](#7-proving-resolution--exit-criteria)
- [8) Close‑Out: PM, CAPA, Hardening](#8-closeout-pm-capa-hardening)
- [9) Appendices (Queries, Templates, Checklists)](#9-appendices-queries-templates-checklists)

---

## 0) Assumptions & Supporting Systems
We explicitly assume:
- **Monitoring/Alerting**: SLOs and **golden signals** (latency, traffic, errors, saturation) with pages on error budget burn; service & dependency dashboards.
- **Observability**: Metrics (Prometheus/Cloud), **structured logs** (LogQL/Cloud), **distributed traces** (OpenTelemetry), exemplars.
- **Delivery Controls**: Feature flags, staged/canary rollouts, instant config rollback; per‑region/POP disables.
- **Runbooks**: Auth service, IdP integration (OIDC/SAML), token/JWKS/key rotation, DB/cache, WAF/CDN, rate limiter, DNS/TLS.
- **Dependencies**: IdP, DB, cache (sessions/tokens), KMS/PKI, rate limiter, WAF/CDN, DNS, time sync (NTP/PTP).

> _Reference: Google SRE monitoring & incident roles (golden signals; IC/OL/CL/Scribe)._

---

## 1) Roles & Incident Structure (ICS‑style)
Assign immediately:
- **Incident Commander (IC)** — overall control, safety & scope, sets comms cadence, approves mitigations.
- **Operations Lead (OL)** — runs technical response, forms workstreams (Auth, IdP, DB/Cache, Edge/WAF, Networking).
- **Communications Lead (CL)** — stakeholder updates (internal/external), status page drafts.
- **Scribe** — timeline, decisions, artifacts (graphs, logs, hashes), who/what/when.
- **Liaison(s)** — IdP/provider/CDN POC; customer support lead.

**Comms Cadence**: every 15–20 min until contained, then 30–60 min.  
**Artifacts**: single incident doc; attach graphs, raw outputs, SHA256SUMS; track rollbacks/flags.

---

## 2) Timeline & Priorities (First Hour Guide)
**0–5 min — Declare & Stabilize**
- Ack page, **declare SEV**, spin an incident room, assign roles.  
- Validate signal ≠ monitoring blip (see §4).  
- **Fast mitigations you can undo**: remove canary; disable suspect feature flag; pin to last‑known‑good config.

**5–15 min — Contain & Bound**
- Scope: region/POP/platform/client‑version/flag cohort.  
- If localized, **shed/shift traffic** from bad slice; keep core auth alive.  
- Start **evidence log** (scribe).

**15–30 min — Hypothesis & Tests**
- Run **Section 3** (“prove it’s an API/web problem”).  
- Branch into **Fishbone** workstreams (§5): Network/Edge, Auth App, IdP, DB/Cache, Policy (WAF/rate limiter), Change/Config.

**30–60 min — Mitigate & Verify**
- Apply **targeted mitigations** (§6) with change numbers.  
- Verify with **golden signals** & **user‑visible canaries**.  
- Decide to end or escalate (more engineers/providers).

---

## 3) Fast Identification — It’s an API/Web Problem: Prove It
> Goal: within **10–15 minutes**, confirm the failure mode and where it sits (edge vs app vs dependency).

### 3.1 Basic Hygiene (run on an auth instance/pod)
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

**Expected**: correct time (UTC synced), resolvable IdP/API names, valid TLS chain & future expiry.

### 3.2 Edge/API L7 Health (prove HTTP issue quickly)
```bash
# From edge/CDN POP or a bastion near players
curl -sS -o /dev/null -w 'code=%{http_code} t_conn=%{time_connect} t_ssl=%{time_appconnect} t_total=%{time_total}\n' \
  https://api.example.com/auth/health

# From an auth pod to upstream IdP metadata & JWKS
curl -sS https://idp.example.com/.well-known/openid-configuration | jq '.issuer,.jwks_uri'
curl -sS https://idp.example.com/.well-known/jwks.json | jq '.keys[].kid' | sort -u
```

**Expected**: 200 on health; reachable IdP metadata; **kid** set(s) present.

### 3.3 Code Mix & Latency Snapshot (dashboards/queries)
- **HTTP code mix** for `/auth` last 30/60 min: 2xx/4xx/5xx stacked.  
- **p50/p95 latency** trend; check if latency ↑ precedes 200s ↓.  
- **Upstream span errors** (IdP/DB/cache).  
- **By slice**: region/POP, platform, client version, feature flag cohort.

**Expected**: pinpoint whether it’s **4xx‑heavy** (policy/time/key), **5xx‑heavy** (backend), or **traffic anomaly**.

### 3.4 Network/Edge Checks (quick wins)
```bash
# Path & packet loss from edge
mtr -u -w -z -c 200 api.example.com
mtr -u -w -z -c 200 idp.example.com

# WAF/CDN deny sampling (paths redacted)
grep -Ei 'deny|ratelimit|blocked|bot' /var/log/waf/*.log | tail -n 200
```
**Expected**: no sustained loss; WAF not blocking auth flows.

---

## 4) Golden Signals & Dashboards (What “Good” Looks Like)
**Healthy** auth exhibits:
- **200 success rate** stable (SLO), **401/403** within normal user error band, **5xx** ~0, **p95 latency** steady, **saturation** below redlines.
- **No** dependency pool exhaustion; **no** rate‑limit spikes; **no** WAF false positives.

**Starter queries** (adapt names/labels):
```promql
# Success rate: 2xx / total
sum(rate(http_requests_total{svc="auth",code=~"2.."}[5m])) 
/ ignoring(code) sum(rate(http_requests_total{svc="auth"}[5m]))

# Code mix per region
sum(rate(http_requests_total{svc="auth"}[5m])) by (region,code)

# Upstream error ratio (IdP/DB/cache)
sum(rate(http_client_errors_total{client="auth"}[5m])) by (upstream)
/ sum(rate(http_client_requests_total{client="auth"}[5m])) by (upstream)

# Latency
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{svc="auth"}[5m])) by (le,region))
```

**Logs (LogQL/SQL‑ish)**
```
{svc="auth", path=~"/auth.*"} |= "error" | json | count_over_time(30m) by (err, region)
```

**Traces (OTel)**
- Filter: `service.name="auth"` `span.kind=client` `peer.service in ("idp","db","cache")` and duration > p95.

---

## 5) Structured Diagnostics — Fishbone with Command Menus
```
     Network/Edge/Peering ──┐   Capacity/Rate‑limit ─┐   DNS/TLS/Policy ──────┐
     (CDN, WAF, POP, loss)   │   (pools/queues)      │   (WAF, bot, certs)    │
                             │                        │                         │
     Host/Kernel/Runtime ────┤   Application/Auth ───┤   Change/Config ───────┤
     (CPU, GC, sockets)      │   (logic, flags)      │   (deploy, rollout)    │
                             │                        │                         │
     IdP/DB/Cache ───────────┘   DDoS/Security ──────┘   Time/Keys/JWKS ──────┘
```

### A) **4xx (esp. 401/403) spike**
**Likely**: clock skew, JWKS/key rotation, issuer/audience mismatch, WAF/bot rule, feature flag gating.  
**Checks**
```bash
date -u; chronyc tracking
curl -sS https://idp.example.com/.well-known/jwks.json | jq '.keys[].kid' | sort -u
grep -Ei 'kid|jwks|aud|iss' /var/log/auth/*.log | tail -n 200
```
**Expected**: server time in sync; token `kid` exists in JWKS; logs not showing `kid not found`/`aud invalid`.

**Mitigate**: refresh JWKS cache; extend skew tolerance briefly; roll back auth config; bypass WAF rule ID blocking `/auth`.

### B) **5xx spike**
**Likely**: IdP/DB/cache errors, pool exhaustion, timeouts.  
**Checks**
```bash
# Resource
uptime; mpstat -P ALL 1 5; free -h
cat /proc/pressure/{cpu,io,memory} 2>/dev/null || true

# Sockets & stack
ss -tnp | head -80
nstat -az | egrep 'TcpRetransSegs|InErrs|RcvbufErrors|SndbufErrors'

# Pools
grep -Ei 'pool|timeout|maxconn' /var/log/auth/*.log | tail -n 200
```
**Mitigate**: add replicas; bump connection pools; raise IdP/DB timeouts modestly; back off retries; scale cache; roll back latest build.

### C) **Latency ↑ then errors**
**Likely**: slow upstream; DNS/OCSP; network jitter.  
**Checks**
```bash
mtr -u -w -z -c 200 idp.example.com
dig +trace idp.example.com
echo | openssl s_client -connect idp.example.com:443 -servername idp.example.com 2>/dev/null \
  | openssl x509 -noout -dates
```
**Mitigate**: route/pin to healthy IdP region; increase client timeout slightly; enable circuit breaker to healthy pool.

### D) **Traffic anomaly**
**Likely**: CDN config, DNS weight, client update throttling.  
**Checks**
```bash
# CDN/WAF status by POP
grep -E 'pop=|denied|ratelimit' /var/log/waf/*.log | tail -n 200

# DNS weights
dig api.example.com +short; dig api.example.com TXT
```
**Mitigate**: restore DNS weights; revert CDN rule; unthrottle client.

### E) **Host/Kernel/NIC saturation (rare for auth, but check)**
```bash
cat /proc/softirqs | sed -n '1,60p'
tc -s qdisc show dev <uplink> | sed -n '1,60p'
ethtool -S <uplink> | egrep 'rx_dropped|tx_dropped|fifo|missed'
```
**Mitigate**: increase pod CPU/memory; tune GC; raise sockets backlog; spread IRQs; enable fq/fq_codel.

---

## 6) Mitigation Menu (Safe & Reversible)
- **Traffic shaping**: remove canary; shift away from bad region/POP; stick to healthy upstream IdP.  
- **Config rollback**: revert auth config/feature flag/env vars impacting `/auth`.  
- **Keys & Time**: force JWKS refresh; temporarily extend clock‑skew tolerance; pause key rotation; fix NTP.  
- **Capacity**: scale replicas; bump DB/cache pool sizes; warm caches; raise autoscaling ceilings.  
- **Policy**: temporarily relax/bypass **WAF/bot** rules shown blocking legit requests; audit after.  
- **Timeouts/retries**: raise client timeout slightly; enable retries with jitter; circuit‑break failing backends.

> _All mitigations need change IDs, owners, start/stop timestamps, and rollback steps recorded by the Scribe._

---

## 7) Proving Resolution & Exit Criteria
- **200 rate** back to baseline; **4xx/5xx** normal; **p95 latency** normal; **saturation** stable.  
- Hold steady ≥ **60–120 min**.  
- Remove temporary relaxations in reverse order; monitor after each removal.  
- IC declares **major incident resolved**; move to monitoring state.

---

## 8) Close‑Out: PM, CAPA, Hardening
- **Blameless Postmortem** within 72h: timeline, contributing factors, detection, impact, what went well/poorly, action items with owners/dates.  
- **Hardening**: pre‑deploy JWKS validation; clock skew alerts; WAF rule tests; IdP regional canaries; SLOs & burn‑rate alerts; synthetic auth checks (headless auth).

---

## 9) Appendices (Queries, Templates, Checklists)

### 9.1 PromQL Snippets
```promql
# Error budget burn (2xx drop proxy): fast burn over 5m
sum(rate(http_requests_total{svc="auth",code!~"2.."}[5m])) 
/ sum(rate(http_requests_total{svc="auth"}[5m]))

# Region x Code matrix
sum(rate(http_requests_total{svc="auth"}[5m])) by (region,code)

# Upstream client errors by upstream
sum(rate(http_client_errors_total{client="auth"}[5m])) by (upstream)
```

### 9.2 LogQL / Pseudo‑SQL
```
{svc="auth"} |= "/auth" | json | stats count() by (status, region, error, upstream)
```

### 9.3 Incident Roles — Quick Card
- **IC**: Owns severity, scope, cadence, approvals.
- **OL**: Drives technical streams, assigns tasks, reports to IC.
- **CL**: Writes stakeholder updates, status page drafts.
- **Scribe**: Timeline, evidence, change log, artifacts.
- **Liaisons**: IdP/CDN/DB owners; CS escalation lead.

### 9.4 Status Update Template (every 15–20 min)
```
[HH:MMZ] SEV-? | Impact: 25% drop in 200s on /auth (global JP-heavy) since HH:MMZ.
Findings: 5xx to IdP increased (502/504) in region tokyo-1; latency up p95.
Actions: Removed canary build; pinned IdP to tokyo-2; scaling auth +2 replicas.
Requests: IdP on-call to confirm regional issue; CDN to share POP errors.
Next Update: HH:MMZ (+20m). IC: <name>. OL: <name>. CL: <name>. Scribe: <name>.
```

### 9.5 Evidence Log Template
```
UTC/JST time | Actor | Action/Command/ChangeID | Scope | Result | Artifact path + SHA256
```

---

**End of runbook.**  
This document combines **SRE incident process** with **Fishbone troubleshooting** and concrete **commands/tests** so responders can move from page → proof → mitigation → durable fix efficiently.

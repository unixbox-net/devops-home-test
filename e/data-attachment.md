
# Shard Performance Report (Europa → Kallichore)

This document summarizes the colored spreadsheet of shard/region metrics across **Periods 3, 4, and 5**. Treat column names (Europa, Ganymede, Callisto, Phobos, Amalthea, Kallichore) as **game shards/realms**, and the rows `eu1 / us1 / us2 / ap1` as **regions/PoPs**.

**Direction:** Lower values are better for all per‑region cells and for `avg`.  
**stdev:** Within‑period time‑series variability (not the cross‑region spread).  
**vol:** Total load for the shard in the period (sessions/matches/requests).

---

## Table of Contents
- [1) Big Picture](#1-big-picture)
- [2) How `avg` is computed (empirical)](#2-how-avg-is-computed-empirical)
- [3) Period‑by‑Period Notes](#3-period-by-period-notes)
  - [Period 3 (peach)](#period-3-peach)
  - [Period 4 (purple)](#period-4-purple)
  - [Period 5 (green, latest)](#period-5-green-latest)
- [4) Region Breakdown (Period 5)](#4-region-breakdown-period-5)
- [5) Shard Breakdown (Period 5)](#5-shard-breakdown-period-5)
  - [Europa](#europa)
  - [Ganymede](#ganymede)
  - [Callisto](#callisto)
  - [Phobos](#phobos)
  - [Amalthea](#amalthea)
  - [Kallichore](#kallichore)
- [6) What’s Working / Not Working (Period 5)](#6-whats-working--not-working-period-5)
- [7) Recommended Follow‑Ups](#7-recommended-follow-ups)
- [8) Appendix — Exact Bias Tables](#8-appendix--exact-bias-tables)
- [9) Assumptions & Data Model (Working Hypotheses)](#9-assumptions--data-model-working-hypotheses)
- [10) Initial Read — “Your Logical Guess”](#10-initial-read--your-logical-guess)

---

## 1) Big Picture
- **Step‑change improvement from Period 3 → 4**, then **partial regression in Period 5**.
- **US1 is consistently best** (lowest numbers); **AP1 is consistently worst**, with the highest cells in most columns.
- **Latest period (5)** winners/strugglers (by `avg`):
  - **Best:** Europa (18.7), Ganymede (19.6)
  - **Middle:** Kallichore (21.8), Phobos (22.5)
  - **Worst:** Amalthea (23.1), Callisto (23.5)
- **Stability in Period 5 (by `stdev`, lower is better):**
  - **Steadiest:** Kallichore (8.6), Amalthea (8.7), Europa (9.0)
  - **Spikiest:** Phobos (13.2), Callisto (14.0)

---

## 2) How `avg` is computed (empirical)
`avg ≈ (eu1 + us1 + us2 + ap1) − bias(period)`

**Estimated biases** (derived from the sheet):
- **Period 3:** ~1.8–1.9 for Europa/Ganymede/Callisto/Phobos; ~1.2 for Amalthea/Kallichore
- **Period 4:** ~3.0 (±0.1) for all shards
- **Period 5:** ~3.2 (±0.1) for all shards

> These biases likely represent a baseline/SLA subtraction or a normalization offset.

---

## 3) Period‑by‑Period Notes

### Period 3 (peach)
- High `avg` and `stdev` across the board.
- AP1 is already the highest region; US1 is the lowest.
- Bias is smaller (~1.2–1.9), so `avg` is closer to the raw region sums.

### Period 4 (purple)
- Clear improvement: `avg` roughly halves vs Period 3 for most shards.
- Variability (`stdev`) narrows materially.
- Period bias increases to ~3.0 (normalized sums drop more).

### Period 5 (green, latest)
- Some regression vs Period 4 (higher `avg`, wider `stdev` for several shards).
- **Region ordering persists:** US1 best → US2 → EU1 → AP1 worst.
- **Volume spikes** (e.g., **Amalthea 500,495**, **Kallichore 330,540**) coincide with higher `avg` and/or `stdev` → **possible load sensitivity**.

---

## 4) Region Breakdown (Period 5)
Average across shards (lower = better):
- **US1:** 4.30 (best)
- **US2:** 5.25
- **EU1:** 7.38
- **AP1:** 7.80 (worst)

**Interpretation:** Prioritize AP1 triage (routing/capacity/autoscale checks), use US1 as the gold baseline.

---

## 5) Shard Breakdown (Period 5)

### Europa
- Regions: eu1 6.6, us1 3.6, us2 4.6, ap1 7.1
- `avg 18.7` = 21.9 − **3.2 bias**
- `stdev 9.0` — steady
- `vol 158,259` — light–moderate load

### Ganymede
- Regions: eu1 6.6, us1 3.6, us2 4.8, ap1 7.7
- `avg 19.6` = 22.7 − **3.1 bias**
- `stdev 9.8` — moderate variability
- `vol 184,492` — moderate load

### Callisto
- Regions: eu1 7.1, us1 4.3, us2 6.0, ap1 9.4
- `avg 23.5` = 26.8 − **3.3 bias**
- `stdev 14.0` — **highest variability**
- `vol 191,113` — moderate load
- **Focus:** AP1 cell (9.4) and time‑series spikes

### Phobos
- Regions: eu1 6.8, us1 4.0, us2 5.7, ap1 9.2
- `avg 22.5` = 25.7 − **3.2 bias**
- `stdev 13.2` — high variability
- `vol 197,375` — moderate‑high load
- **Focus:** AP1 cell (9.2) and spikiness

### Amalthea
- Regions: eu1 8.8, us1 5.3, us2 5.3, ap1 6.9
- `avg 23.1` = 26.3 − **3.2 bias**
- `stdev 8.7` — fairly steady
- `vol 500,495` — **very high load**
- **Focus:** EU1 (8.8) and capacity effects

### Kallichore
- Regions: eu1 8.4, us1 5.0, us2 5.1, ap1 6.5
- `avg 21.8` = 25.0 − **3.2 bias**
- `stdev 8.6` — steady
- `vol 330,540` — high load

---

## 6) What’s Working / Not Working (Period 5)

**Working well**
- **Shards:** Europa, Ganymede (lowest `avg`)
- **Regions:** US1 (best baseline), US2
- **Stability:** Kallichore, Amalthea, Europa (`stdev` ≤ 9.0)

**Not working so well**
- **Shards:** Callisto (highest `avg` & `stdev`), Phobos (high `stdev`)
- **Regions:** AP1 (highest across shards), EU1 pockets (e.g., Amalthea 8.8)
- **Load sensitivity suspects:** Amalthea (500k vol), Kallichore (330k vol)

---

## 7) Recommended Follow‑Ups
1. **AP1 triage** — routing/peering validation, capacity headroom, autoscaler thresholds, and instance parity.
2. **Stability investigations** — deep‑dive on Callisto/Phobos time‑series (tick overruns, GC pauses, DB hotspots).
3. **Use Period 4 as SLO target** — alert when any shard×region deviates by > X% from Period‑4 levels.
4. **Dashboards** — per region: p95/p99 RTT/loss/jitter, server tick breakdown, queue depth, autoscaler events overlaid with `avg`/`stdev`.

---

## 8) Appendix — Exact Bias Tables

### Period 5 (sum of regions − avg = bias)
- Europa: **21.9 − 18.7 = 3.2**
- Ganymede: **22.7 − 19.6 = 3.1**
- Callisto: **26.8 − 23.5 = 3.3**
- Phobos: **25.7 − 22.5 = 3.2**
- Amalthea: **26.3 − 23.1 = 3.2**
- Kallichore: **25.0 − 21.8 = 3.2**

### Period 4
- Europa: **20.8 − 17.9 = 2.9**
- Ganymede: **22.9 − 19.9 = 3.0**
- Callisto: **20.5 − 17.5 = 3.0**
- Phobos: **20.5 − 17.5 = 3.0**
- Amalthea: **20.0 − 17.0 = 3.0**
- Kallichore: **18.5 − 15.4 = 3.1**

### Period 3
- Europa: **38.3 − 36.5 = 1.8**
- Ganymede: **38.3 − 36.5 = 1.8**
- Callisto: **38.6 − 36.7 = 1.9**
- Phobos: **38.6 − 36.7 = 1.9**
- Amalthea: **33.8 − 32.6 = 1.2**
- Kallichore: **33.2 − 32.0 = 1.2**

---

## 9) Assumptions & Data Model (Working Hypotheses)

**Entities**
- **Columns (Europa…Kallichore):** game shards/realms.
- **Rows (eu1, us1, us2, ap1):** regions/PoPs reporting the shard’s KPI for the period.
- **Periods (3, 4, 5):** sequential time buckets (e.g., releases/sprints/weeks).

**Metrics**
- **Directionality:** Lower is better for regional cells and `avg`.
- **`avg` (aggregate):** `avg ≈ eu1 + us1 + us2 + ap1 − bias(period)` where bias is roughly:
  - P3: ~1.8–1.9 (E/G/C/P), ~1.2 (A/K)
  - P4: ~3.0 (±0.1)
  - P5: ~3.2 (±0.1)
  This likely represents SLA/baseline subtraction or normalization.
- **`stdev`:** Within‑period time‑series variability (not cross‑region spread). High = spiky experience.
- **`vol`:** Per‑shard total load in the period (sessions/matches/requests). Not used in `avg` math, but may correlate with higher `avg`/`stdev` under load.

**Data Quality / Caveats**
- `avg` is not a mean; summing regions without subtracting bias will overshoot.
- Period 3 uses two slightly different biases (E/G/C/P vs A/K), so don’t reuse a single scalar for all columns.
- Decimal precision is 0.1; rounding may introduce ±0.1 noise.

---

## 10) Initial Read — “Your Logical Guess”

1) **There was a global improvement between Period 3 → 4**, likely a config/infra rollout (latency/error reductions, tighter variability).  
2) **Period 5 shows partial regression under higher load**, especially on shards with heavier `vol` (e.g., **Amalthea 500k**, **Kallichore 331k**).  
3) **Regional ordering is stable:** **US1 best** → US2 → EU1 → **AP1 worst**. Root causes for AP1 likely include routing/peering paths, capacity, instance type parity, or scrubbing/Anycast decisions.  
4) **Shard‑specific hotspots:**  
   - **Callisto** — highest `avg` and `stdev` in P5; AP1 (9.4) is the biggest contributor.  
   - **Phobos** — high `stdev` in P5; AP1 (9.2) + general volatility.  
   - **Amalthea** — very high `vol` with elevated EU1 (8.8); potential capacity/affinity skew.  
5) **Operational interpretation:** Use **US1** as the golden baseline; drive AP1 parity. Treat **Period 4** levels as provisional SLO targets; alert on % deviations in P5+.

**Quick validation checks you can run next**
- Recompute `sum(regions) − avg` to confirm the per‑period bias.  
- Plot `avg` vs `vol` to eyeball load sensitivity.  
- Inspect P5 time series for Callisto/Phobos to identify spike patterns (tick overruns, GC, DB hotspots).

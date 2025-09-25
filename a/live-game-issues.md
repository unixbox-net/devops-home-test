# DDO Live-Issue Story (Player Perspective) — Markdown


## One-Paragraph Summary

As a long-time DDO player, prime-time raids regularly degrade into rubber-banding and input freezes despite a strong local setup, pointing to systemic server/runtime and/or network issues that have persisted across restarts and even a 64-bit migration. The studio’s limited, non-quantitative comms have built trust debt while the core experience remained unstable, pushing players to leave or avoid peak play. I would publish concrete playability SLOs, pause non-essential features until those SLOs are met, own the technical debt in a transparent roadmap (up to and including staged rewrites), and use disciplined operations with time-boxed player-first mitigations. Success is measured not by promises but by sustained improvements in **p95 action→ack**, **missed-tick %**, login reliability, and a visible reduction in community “lag” reports.


## Title
**When a 12-Person Raid Becomes a Slideshow: A Player’s Account of DDO’s Lag Problem**

---

## Context & Assumptions (explicit, numeric, testable)

- **Where I play:** North America (West). Residential fiber **3 Gbps**; workstation-class PC.
- **Expected network:** **25–40 ms** median RTT to NA servers; **p95 jitter ≤ 20 ms**; **p95 loss ≤ 1%**.
- **Population (assumed):** Global CCU **2–4k** on event nights; NA **2–3k**; first-hour spike **+15–20%**.
- **Instance density (assumed):** Target **≤ 110** players per shared space; hard cap ~**120**.
- **Voice:** In-client voice (Opus) **16–24 kbps**, target **MOS p95 ≥ 3.8**.
- **Player SLO expectations (as a paying customer):**  
  - **Action→Ack p95 < 80 ms** (button press to server acknowledgment)  
  - **Login success ≥ 99.5% within 5 minutes**  
  - **Raid stability ≥ 99%** session survival
- **Background (observed over years):**  
  - Studio communication tends to be minimal/vague re: “lag.”  
  - **Weekly restarts** are used because performance degrades with uptime.  
  - **32→64-bit migration** occurred; gameplay lag **unchanged or worse** in crowded content.

---

## The Incident (as a player, not an engineer)

- **Setting:** Prime time, 12-person raid.  
- **Symptom:** Severe rubber-banding (movement snaps back), multi-second input freezes, enemies updating in bursts, voice comms stuttering.  
- **Frequency:** Nightly; reproducible during peak.  
- **Local sanity checks:** No local CPU/GPU saturation, no home network loss, concurrent apps (voice/stream) fine.

**Bottom line:** The game becomes intermittently unplayable. Groups abandon raids, mechanics get cheese-skipped, and “fun” turns into “fight the netcode.”

---

## How the Company Handled It (from my seat)

- **Communication:** Generally high-level (“we’re looking into lag”), few quant metrics, rare postmortems with concrete causes/remediations.
- **Operational workarounds:** **Weekly restarts** to reset performance drift; occasional emergency restarts.
- **Platform changes:** **64-bit upgrade** and some infra tweaks; **no material change** to peak-time lag in raids.
- **Expectation management:** Community managers extend events, acknowledge issues in forums, but **tangible core-lag fixes remain limited**.

---

## Player Impact

- **Immediate gameplay:**  
  - Parties **abandon raids** mid-run.  
  - **Mechanics skipped** or simplified to avoid desync death spirals.  
  - Players **shorten sessions** or switch games for the night.
- **Social layer:**  
  - DDO doubles as a **weekly hangout/role-play** table; lag **breaks the “table” vibe**.  
  - **Guild nights canceled** due to instability.
- **Behavioral churn:**  
  - Veterans tolerate; **returning/new players bounce** quickly.  
  - “Lag” shifts from **bug** to **player expectation**.

---

## Product & Company Impact (my read)

- **Trust debt:** Vague comms + persistent lag = **forums full of “unplayable tonight” threads**; skepticism grows.
- **Revenue drift:** Perception of **store-first/P2W** content while core performance stagnates → **priority misalignment** in the eyes of players.
- **Expansion quality signal:** Content often feels **rushed/recycled**, compounding frustration when the **core experience is unstable**.
- **Brand erosion:** The **DDO spirit** (co-op + RP) is harmed in ways KPIs undercount; players **vote with feet**. This reflects poorly on associated brands (Hasbro, Wizards of the Coast).

---

## What I Would Have Done Differently (and Why)

1. **Radical Transparency, Early**  
   - Publish **hard metrics** (login success, action→ack histograms, tick stability) and **weekly postmortems** for major outages.  
   - Explain what’s known/unknown, with **public exit criteria** (“p95 action→ack < 80 ms in 12-person raids for 14 days”).

2. **Prioritize Core Playability Over Features**  
   - **Freeze non-essential feature work** until **core SLOs** are met.  
   - Establish **error budgets**: if the budget is burned, **feature releases pause** and teams swarm reliability.

3. **Own the Technical Debt Narrative**  
   - If the engine/networking layer is the root cause, **say so**.  
   - Present a **roadmap**: targeted refactors, staged rewrites, or even **DDO 2.0** planning if needed.

4. **Operational Discipline**  
   - Move from “pets” to “cattle”: immutable builds, deterministic rollouts, **blue/green** for world servers.  
   - **Measure and enforce**: label hygiene, cardinality limits, and **tiered retention** for telemetry so we can see and fix regressions quickly.

5. **Player-First Mitigations During Fix Window**  
   - **Time-boxed** changes that materially help:  
     - Prefer lower-jitter regions/IPv6 where possible.  
     - Reduce high-cost updates (cosmetics, pets, effect spam) during peak via **feature flags**.  
     - Increase **raid tick budgets** and adjust mechanics that are most lag-sensitive.

---

## Lessons of the Past (Why This Keeps Happening)

- **Partial fixes** (e.g., 64-bit) **without addressing core bottlenecks** (gameplay snapshotting, server tick pacing, transport backpressure) don’t move player-perceived SLOs.  
- **Performance decay with uptime** hints at **fragmentation/GC leaks**, **queue growth**, or **stateful subsystems** that need redesign.  
- **Silence/vagueness** converts isolated frustration into **community-wide cynicism**.

---

## What “Good” Would Look Like (Player-Visible Outcomes)

- **Published SLOs** for playability (e.g., *“p95 raid action→ack < 80 ms; missed-tick < 1%”*).  
- **Weekly reliability notes** summarizing where lag appeared, why, and what changed.  
- **Measurable improvement** over a month: fewer forum “lag” threads, **retention uptick** on raid nights, increased **voice MOS** scores.

---

## Assumptions Call-Out (so a reviewer can test me)

- **Network baselines** (25–40 ms median RTT, jitter/loss budgets) are **measurable** via client histograms.  
- **Population estimates** come from third-party audits; refine with internal CCU.  
- **Voice quality** assumes Opus at 16–24 kbps; validate with MOS estimators.  
- **SLO targets** (action→ack, login, raid survival) are **player-centric** and should be tuned with real telemetry.

---

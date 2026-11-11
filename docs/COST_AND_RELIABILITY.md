# FaceTrack — Cost Structure and Reliability by Scenario

Prepared 25 October 2026. The summary in `CLIENT_PROJECT_DOCUMENT.md` §4 is drawn from this document. Architecture authority remains `MASTER_DESIGN.md`.

This document compares historical planning scenarios. See the [100-student Azure pilot budget](IGDTUW_PILOT_BUDGET.md) for the current deployment estimate. Current executable setup and verified status live in [`INSTALLATION.md`](INSTALLATION.md) and [`PROGRESS.md`](../PROGRESS.md).

**Read this first.** Prices below were read from provider pages on 25 October 2026 unless marked *derived* (calculated from a verified price) or *estimate* (my assumption, not a quote). Availability and recognition figures are **planning targets, not measurements and not SLAs**. FaceTrack has no institute-scale benchmark yet.

Exchange rates used: **₹94.95 per US$** (banklive.net, 25 Oct 2026) and **US$1.1202 per €** (EUR/USD close, 23 Oct 2026).

---

## 1. Key cost findings

- The measured worker pipeline for a 12-frame clip took **356 ms** on the Mac CPU (PROGRESS.md). Recognition is exact matching against 40–60 enrolled students. Nothing in the pipeline needs a GPU. **Effect:** GPU line removed. 7,200 clips/month at an assumed 10 s each is about **20 CPU-hours/month**.
- Hetzner raised prices on 1 Apr and 15 Jun 2026. The cheap CX/CAX lines are listed as unavailable to order; the orderable 2 vCPU/4 GB CPX22 is **€19.99 (≈$22.39)**. Servers are in the EU, not India. **Effect:** Cheaper and in-country: AWS Mumbai t4g.small is **$0.0112/h (≈$8.18/mo)**.
- The API, Redis and Celery worker already run together in the Windows compose profile. Render's smallest 1-CPU/2 GB service is $25 and its managed Redis is $10–$20. **Effect:** One VM runs all three. Redis is self-hosted.
- Maintenance and operations staff time is people time, not infrastructure. **Effect:** Listed as a separate, institute-decided support line.
- Cloudflare DNS/SSL and Sentry both have free plans that suit this scale (plan limits not re-verified here). **Effect:** $0 until limits are hit.
- Free Supabase is 500 MB database, 1 GB storage, **5 GB egress**, **no backups**, and **projects pause after 1 week of inactivity**. **Effect:** See the egress calculation in §3. A free project can also pause over a holiday week.
- `buffalo_sc` / `w600k_mbf` / SCRFD-500M are published for **non-commercial research only**. InsightFace offers commercial licences for these models but publishes no prices. **Effect:** **Unpriced licence risk.** Not in any total below.

---

## 2. The workload that drives cost

Baseline is a mid-sized college: 3,000 students, 60 rooms, 360 sessions per day, 20 teaching days, so **7,200 clips per month**.

Cost drivers, in order:

1. **Clip size** drives Supabase egress, because the worker downloads every clip. Capture currently uses `ResolutionPreset.high` with no bitrate cap, so real clip size is **unmeasured**. The design allows up to 50 MiB class clips and 25 MiB enrolment clips and prefers 5–15 s. The tables below show 10 MB and 15 MB cases.
2. **Burst, not monthly volume, sets worker size.** Lectures start on the hour, so uploads cluster. Time to clear a burst is `ceil(clips / slots) × seconds per clip`:

| Burst | 3 s/clip | 10 s/clip |
|---|---|---|
| 20 clips, 1 slot | 60 s | 200 s |
| 20 clips, 2 slots | 30 s | 100 s |
| 60 clips, 2 slots | 90 s | 300 s |
| 60 clips, 4 slots | 45 s | 150 s |

   Seconds per clip in the cloud is unmeasured. Only 356 ms of model pipeline time was measured, excluding download, decode and start-up.
3. **Database and auth** are small. Sessions and attendance rows are tiny next to video.

---

## 3. Scenarios, cost and reliability

Monthly USD with INR in brackets (₹94.95/$). Totals are infrastructure only.

### S0 — Local demo estimate (Mac + free Supabase)
- **Cost:** $0.
- **Availability:** whenever the Mac is awake and the phone is on USB. Not a service.
- **Recognition:** same model and thresholds as every other scenario.
- **Use for:** demonstrations on 28 October only.

### S1 — Free pilot, up to about 60–100 students, about 20 sessions/day
- **Stack:** Supabase Free + one free VM (Oracle Always Free Ampere A1: 2 OCPU, 12 GB, 200 GB block storage, 10 TB/month egress) or the existing Mac.
- **Cost:** $0.
- **Limits that bite:**
  - Supabase Free egress is 5 GB. At 10 MB/clip that is about **512 clips/month**; at 15 MB about **341**. A pilot of 20 sessions/day over 20 days is 400 clips, and enrolling 100 students at up to 25 MB adds up to 2.4 GB. The budget is gone in the first month.
  - Free projects pause after 1 week of inactivity (exam or holiday weeks), and have no backups.
  - Oracle may reclaim Always Free instances idle for 7 days (95th-percentile CPU, network and, on A1, memory all under 20%), and A1 capacity can be unavailable at creation ("out of host capacity").
  - The worker agent polls the API every 2 s when idle, so API hosts that sleep when idle (free tiers) are a poor fit.
- **Availability target (estimate):** 95–98%, roughly 15–36 h of downtime per month. No backups means a database loss is a restart from zero.
- **Verdict:** acceptable for a closed trial with volunteers. Not for a class that depends on it.

### S2 — Paid small deployment, up to about 1,000 students, up to 120 sessions/day
- **Stack:** Supabase Pro ($25: 8 GB database, 100 GB storage, 250 GB egress, 7-day daily backups, no inactivity pause, $10 compute credit covers one Micro) + one AWS Mumbai **t4g.medium** (2 vCPU, 4 GiB) running API, Redis and one Celery slot.
- **Cost:** $25 + $16.35 (*derived*: t4g.small $8.18 × 2) + about $3 disk and snapshots (*estimate*) = **≈ $44 (₹4,200)**.
- **Capacity:** 2,400 clips/month, 23–35 GB egress, well inside 250 GB.
- **Availability target (estimate):** about 99%, roughly 7 h/month. Single VM, single worker slot, no failover. Backups exist, but a restore test has not been done.
- **If it fails:** clips stay pending and attendance stays unassessed by design, so a teacher can fall back to a manual roll call.

### S3 — Mid-sized college baseline, 3,000 students, 360 sessions/day
- **Stack:** Supabase Pro + t4g.medium (API + Redis) + t4g.large worker (2 slots; $32.70 *derived*) + about $5 disk/snapshots (*estimate*).
- **Cost:** **≈ $79 (₹7,500)**. Egress is 70–105 GB, within the 250 GB included.
- **Burst:** 60 simultaneous clips clear in about 90 s (3 s/clip) to 300 s (10 s/clip) on 2 slots. Both figures are untested; the benchmark in §6 decides whether 4 slots are needed.
- **Availability target (estimate):** 99–99.5% (about 3.7–7 h/month).
- **With high availability:** add a second API node, a second worker and a load balancer, plus tested failover. **≈ $130 (₹12,300)** (*estimate*; load-balancer price not verified). Target 99.9% (about 44 min/month) **only after a failover test passes**.

### S4 — Large university, 10,000–20,000 students, up to 2,400 sessions/day
- **Stack:** Supabase Pro with a Small compute add-on ($15, verified; larger sizes not verified) + t4g.large API node + two t4g.xlarge workers (8 vCPU in total; $65.41 each *derived*) + egress overage.
- **Egress:** 48,000 clips × 10–15 MB = 469–703 GB per month. Overage beyond 250 GB is $0.09/GB, so **≈ $20–$41**.
- **Cost:** **≈ $220–$290 (₹20,900–₹27,500)**.
- **Availability:** needs the HA design from S3 plus load testing at 20 simultaneous classes, which `MASTER_DESIGN.md` makes the institute gate.

| Scenario | Students | Monthly (USD) | Monthly (INR) | Availability target | Recognition evidence available |
|---|---|---|---|---|---|
| S0 Demo | 20–50 | $0 | ₹0 | Demo only | Two real captures |
| S1 Free pilot | ≤100 | $0 | ₹0 | 95–98% | Pilot would create it |
| S2 Small paid | ≤1,000 | ≈ $44 | ≈ ₹4,200 | ≈ 99% | Pilot gate required |
| S3 College | 3,000 | ≈ $79 (HA ≈ $130) | ≈ ₹7,500 (≈ ₹12,300) | 99–99.5% (HA 99.9%) | Pilot gate required |
| S4 University | 10,000–20,000 | ≈ $220–290 | ≈ ₹20,900–27,500 | HA design plus load test | Pilot gate required |

### Why not a GPU?
A GPU does not improve accuracy by itself. It only makes sense for continuous room-camera streaming or much larger models.
- Always-on Runpod 16 GB class (A4000/A4500) is **$0.58/h**: about **$128/mo** for 10 h × 22 days. That alone costs more than the full S3 stack.
- Serverless, billed per second, would be **≈ $6–$12/mo** at 7,200 clips and 5–10 s each (*derived* by dividing the hourly rate by 3,600; Runpod's page does not publish per-second rates, and cold-start model loading is billed). That is cheap, but the CPU stack is simpler and no slower for this workload.

---

## 4. Recognition reliability — what is known and what is not

**Published model benchmarks (controlled data):** the `buffalo_sc` pack (MobileFaceNet trained on WebFace600K) reports **IJB-C 95.02%** (1:1 at FAR ≤ 1e-4), **LFW 99.70%**, CFP-FP 98.00%, AgeDB-30 96.58% (InsightFace model zoo). SCRFD-500M detection reports 90.57 / 88.12 / **68.51** on WIDER FACE easy / medium / hard. The hard subset is the small, distant, dark faces typical of back rows.

**Independent evidence that classroom conditions are worse:** one 2026 offline study (13,000 images, 1,600 identities) measured top-1 accuracy of **87.93% for Dlib but 77.27% for ArcFace**, and reported low light as a failure case. This is a different dataset, so it is a warning and not a prediction for FaceTrack. Most classroom-attendance papers I found report benchmark-dataset accuracy (for example 97.81% on KDEF), not live-classroom results, and should not be quoted as expected performance.

**FaceTrack's own evidence is thin:**
- One real low-light two-person capture: 12 sampled frames, 23 detections, 14 quality rejects, **1 of 2 students corroborated** (7 hits). Teacher confirmed both Present.
- Independent ML acceptance is **1 of 6** scenarios; the remaining five recordings are on hold.
- Target of presence recall above 95%, precision at least 99.5% and false attendance at most 0.1% is **unproven**.

**What I can honestly promise:**
- After processing, an unmatched student starts as draft Absent. A teacher must verify the draft before publishing. A failed job alone does not generate absence evidence.
- A false match is the risk that matters. Two corroborating frames reduce it but do not prove identity or liveness (a photo can still pass).
- I cannot give a classroom accuracy percentage today. The earliest honest number comes from the pilot gate: at least 100 students, 30 independent sessions, 3 rooms or days, with absentees and non-roster people, reported with confidence intervals.

**Levers, cheapest first:**

| Lever | Cost | Expected effect |
|---|---|---|
| Capture protocol: walk the sweep, two short sweeps, front-of-room standing | ₹0 | Most likely biggest gain on back rows and low light; needs testing |
| Cap capture at about 720p and fix bitrate | ₹0 | Cuts egress and upload time; may hurt small faces, so test before adopting |
| Tune quality floor and thresholds on pilot data (never on test clips) | ₹0, needs pilot | Reduces over-rejection (14 of 23 crops rejected in the one real run) |
| Commercial licence for these or better models | Unknown; InsightFace quote required (contact@insightface.ai) | Legal right to deploy; higher-accuracy proprietary models are offered |
| Permissive models (for example OpenCV YuNet detector + SFace recognizer) | ₹0 licence | Different accuracy; I have not verified their licences or numbers, and one study above ranked SFace far below ArcFace. Needs a full re-evaluation and re-enrolment |
| Fixed room cameras | Hardware not priced here | Consistent angle and light; changes the product |

---

## 5. Decisions needed before any paid rollout

1. **Model licence.** Email InsightFace for a commercial quote, or choose permissive weights and re-run the evaluation. This is the largest unpriced item and the only one that can block deployment.
2. **Data location.** AWS Mumbai keeps video in India. Hetzner's orderable regions are in the EU. Indian data-protection applicability needs institute review (as already noted in `MASTER_DESIGN.md`).
3. **Supabase plan.** Move to Pro before real enrolment: free egress cannot cover it and has no backups.
4. **Clip size.** Measure real class and enrolment clip sizes on the Samsung phone and web, then recompute egress.
5. **Support line.** Decide whether the institute funds the maintenance and security-review time (not infrastructure).

## 6. Measurements that would replace estimates

| Measurement | Replaces |
|---|---|
| Median and 95th-percentile MB per class clip and enrolment clip | Egress and upload assumptions |
| End-to-end seconds per clip on a t4g.medium (download, decode, inference, commit) | The 3 s and 10 s guesses |
| 1/5/10/20 simultaneous clips on 1, 2 and 4 slots | Worker sizing in S3/S4 |
| Restore of a Supabase Pro backup and a worker-kill test | Availability targets |
| Pilot gate (100 students, 30 sessions, 3 rooms) | Every recognition claim |

## Sources

- Supabase pricing: https://supabase.com/pricing
- Hetzner 2026 price changes and availability: https://agentdeals.dev/hetzner-pricing-2026 and https://privatedevops.com/news/hetzner-june-2026-cloud-price-increase-what-to-do
- AWS t4g.small Mumbai price: https://sparecores.com/server/aws/t4g.small
- Runpod hourly GPU prices: https://www.runpod.io/pricing ; billing rules: https://docs.runpod.io/serverless/pricing
- Render prices: https://render.com/pricing
- Oracle Always Free: https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
- InsightFace model benchmarks and non-commercial terms: https://github.com/deepinsight/insightface/blob/e68b8b076fb11e9f75c87244d234385f0f318181/model_zoo/README.md ; commercial licensing: https://www.insightface.ai/solutions/face-recognition-licensing
- Classroom study (Dlib 87.93%, ArcFace 77.27%): https://www.itm-conferences.org/articles/itmconf/pdf/2026/01/itmconf_etmis2025_01018.pdf
- Exchange rates: https://banklive.net/en/convert/usd-to-inr ; https://www.poundsterlinglive.com/history/EUR-USD-2026

# FaceTrack — Project Overview & Deployment Cost Analysis

**Client & Institutional Leadership Briefing** · October 2026

---

## 1. Project Overview & Problem Statement

- **What is FaceTrack:** FaceTrack is an automated, cross-platform classroom attendance system that identifies enrolled students from a brief 10–15 second video scan recorded on a faculty member's smartphone or web browser.
- **The Problem:** Traditional manual roll calls and paper sign-in sheets waste 10 to 15 minutes of valuable instructional time every lecture, enable fraudulent proxy attendance, and create administrative burdens without real-time records.
- **What It Solves Exactly:** FaceTrack reduces manual roll calls and dependence on dedicated scanners by using privacy-controlled computer vision to propose who was observed, while keeping faculty in complete control to review, adjust and authoritatively publish attendance.

---

## 2. How the AI Model Works (Models, Libraries & Process)

Rather than acting as an unpredictable "black box", FaceTrack combines established, high-performance computer vision models and standard open-source libraries:

### Specific Models & Libraries Used:
- **Face Detection Model — SCRFD (`det_500m.onnx`):** A compact detector that locates multiple faces in sampled video frames. Small, distant, dark or heavily turned faces remain a known limitation that requires classroom testing.
- **Biometric Recognition Model — ArcFace / MobileFaceNet (`w600k_mbf.onnx`):** An acclaimed deep convolutional neural network that converts facial contours into high-precision, 512-dimensional mathematical feature vectors.
- **Execution & Inference Engine — ONNX Runtime (`onnxruntime`):** High-speed cross-platform runtime that executes the deep learning models efficiently on CPU or cloud GPU hardware.
- **Media Decoding & Preprocessing — OpenCV (`cv2`) & FFmpeg:** FFmpeg validates and decodes bounded video input, while OpenCV extracts frames, applies crop-quality checks and aligns faces using five landmark points.
- **On-Device Pose Guidance — Google ML Kit & MediaPipe:** Runs lightweight face-tracking directly inside the user's phone (ML Kit on Android) or browser (MediaPipe) to guide head turns in real time without sending live camera feeds to the cloud.
- **Roster Matching Engine — NumPy:** Performs ultra-fast vector cosine similarity calculations (`dot product`) against the enrolled class roster in memory.

### Step-by-Step AI Recognition Process:
1. **Finds Faces in the Video (OpenCV + SCRFD):** During the classroom sweep, OpenCV samples frames and SCRFD proposes face crops. Quality checks reject many blurred, very small or low-contrast crops.
2. **Creates a biometric template (ArcFace via ONNX Runtime):** ArcFace converts an aligned face crop into a normalized 512-number vector. This vector remains sensitive biometric data: FaceTrack encrypts active templates and keeps raw private video only for the bounded review/retention period.
3. **Compares Only Within the Class Roster (NumPy):** The model does not search the entire college directory. NumPy performs fast matrix multiplication comparing detected faces only against the 40–60 students enrolled in that specific class for speed and accuracy.
4. **Multi-Frame Double Check:** To reduce accidental misidentification, the algorithm requires compatible recognition evidence in at least two temporally separated frames. This corroboration does not prove identity or liveness.
5. **Suggests Presence (Never Absences):** Corroborated matches are highlighted as **"Proposed Present"**. Anyone looking away, obscured, or absent is left as **"Unassessed"** for the teacher's final human judgment.

---

## 3. How the User Interface (UI) Works

The apps are designed for everyday faculty and students with zero learning curve:

### Student Interface:
- **Guided Camera Outline:** During enrolment, students see a face guide with simple front/left/right/up/down cues and progress indicators. This is capture guidance, not identity or liveness verification.
- **Classes and enrolment:** Students can link an approved identity, request classes through join codes and follow face-enrolment status.
- **Published history:** Students can view only their own published session results and the assessed attendance percentage. Unassessed and excused rows are excluded from that percentage.

### Teacher Interface:
- **Controlled session opening:** The teacher opens a scheduled or manually created session, which freezes the approved class roster for that session.
- **Camera Sweep:** A live 10-second sweep camera screen opens with an on-screen timer. Audio is muted automatically.
- **Interactive Review Sheet:** Within seconds of upload, the student roster displays clear color-coded statuses:
  - 🟢 **Proposed Present:** Corroborated model evidence that still requires a teacher decision.
  - ⚪ **Unassessed:** Clearly flagged for the teacher to quickly mark *Present*, *Absent*, *Late*, or *Excused*.
- **One-Tap Publish & Export:** The teacher confirms the review with one tap on **"Publish"**. Instant download buttons for official PDF and CSV attendance sheets appear immediately.

---

## 4. Deployment Cost Analysis

The figures below are planning estimates, not provider quotes or measured production capacity. Pricing, taxes, data transfer, support and required compute must be revalidated before procurement. FaceTrack has not yet demonstrated institute-scale throughput.

### Baseline Reference: Mid-Sized College Campus
- **Student Body:** 3,000 active students | **Faculty:** 120 teaching faculty members
- **Active Classrooms:** 60 lecture halls & labs (6 sessions/day = 360 sessions daily)
- **Monthly Volume:** ~7,200 attendance scans per month

---

### Monthly & Annual Infrastructure Cost Breakdown (Full Campus)

| Component | Purpose & Provider | Monthly (USD) | Annual (USD) | Annual (INR @ ₹84/$)|
|---|---|---|---|---|
| **Core API & App Hosting** | High-availability backend services (AWS / Render) | $35 / mo | $420 / yr | ₹35,280 |
| **Managed Database & Auth** | Secure PostgreSQL, user authentication, daily backups (Supabase / AWS RDS) | $25 / mo | $300 / yr | ₹25,200 |
| **AI Processing Workers** | Dedicated CPU/GPU compute during academic hours (Runpod / AWS EC2) | $75 / mo | $900 / yr | ₹75,600 |
| **Storage & Bandwidth** | Temporary video buffer (24-hr purge) & report storage (AWS S3) | $15 / mo | $180 / yr | ₹15,120 |
| **Task Queue & Cache** | High-speed task management broker (Redis) | $10 / mo | $120 / yr | ₹10,080 |
| **Operational Services** | Health monitoring, edge protection, automated PDF reports (Sentry / Cloudflare) | $45 / mo | $540 / yr | ₹45,360 |
| **Maintenance & Operations** | Ongoing updates, patching, database tuning, security audits | $150 / mo | $1,800 / yr | ₹1,51,200 |
| **TOTAL** | | **$355 / mo** | **$4,260 / yr** | **₹3,57,840** |

---

### Scaling Across Institutional Sizes

| Institutional Tier | Student Size | Daily Classes | Monthly (USD) | Annual (USD) | Annual (INR) |
|---|---|---|---|---|---|
| **Pilot / Small Test Cohort** | 50 – 200 | 5 – 20 | **$12 – $15 / mo** | $144 – $180 / yr | ₹12,000 – ₹15,120 |
| **Tier 1: Small School / Dept** | 500 – 1,000 | 60 – 120 | **$180 / mo** | $2,160 / yr | ₹1,81,440 |
| **Tier 2: Mid-Sized College (Baseline)** | 2,500 – 5,000 | 300 – 600 | **$355 / mo** | $4,260 / yr | ₹3,57,840 |
| **Tier 3: Large University Campus** | 10,000 – 20,000 | 1,200 – 2,400 | **$780 / mo** | $9,360 / yr | ₹7,86,240 |

---

### Ultra-Low-Cost Online Setup for Small Test Users (50–200 Students)

For a department, club, or pilot school wanting to run a **100% online cloud deployment** with real devices over mobile 4G/5G/Wi-Fi (no USB cables, no local laptops tethered), FaceTrack runs smoothly on lightweight, budget-friendly cloud tiers:

| Component | Cost-Effective Cloud Service | Monthly Cost (USD) | Monthly Cost (INR) |
|---|---|---|---|
| **Core API & Web Hosting** | Render Starter or Fly.io (Containerized FastAPI with free HTTPS/SSL) | ~$5 – $7 / mo | ₹420 – ₹580 |
| **Database & User Auth** | Supabase Free/Hobby Tier (PostgreSQL + Auth + 1 GB storage) | $0 / mo | ₹0 |
| **AI Inference & Worker** | 1 Basic Cloud VPS (Hetzner / DigitalOcean 2 vCPU) running CPU ONNX + Redis | ~$5 – $6 / mo | ₹420 – ₹500 |
| **Edge & Domain Security** | Cloudflare Free SSL / DNS + automated 24-hr video purge | $0 / mo | ₹0 |
| **TOTAL TEST PILOT DEPLOYMENT**| **Fully autonomous online system for test users** | **~$12 – $15 / mo** | **~₹1,000 – ₹1,260 / mo** |

- **Zero Local Hardware Dependencies:** Completely live on the internet. Teachers and students test directly on their personal Android phones or web browsers from any classroom.
- **Performance must be measured:** The local demo has measured worker-only processing on one short clip, but upload, queue and end-to-end latency plus multi-class capacity remain unverified. Pilot sizing must follow load tests on the chosen cloud machine.
- **Seamless Upgrade Path:** When expanding from 100 students to 3,000 students, the exact same database and API are retained—only the background worker compute expands to GPU capacity.

# FaceTrack — Project Overview & Deployment Cost Analysis

This is a client-facing overview. For executable setup use [`INSTALLATION.md`](INSTALLATION.md); for the measured implementation state use [`PROGRESS.md`](../PROGRESS.md). Planning costs and reliability targets below are not production measurements.

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
3. **Compares Only Within the Class Roster (NumPy):** The model does not search the entire college directory. NumPy performs fast matrix multiplication comparing detected faces only against the students enrolled in that specific subject for speed and accuracy.
4. **Multi-Frame Double Check:** To reduce accidental misidentification, the algorithm requires compatible recognition evidence in at least two temporally separated frames. This corroboration does not prove identity or liveness.
5. **Suggests Presence (Never Absences):** Corroborated matches are highlighted as **"Proposed Present"**. Anyone not matched is shown as **"Not recognized"** or **"Unassessed"** for the faculty member's final judgment; nobody is marked absent automatically.

---

## 3. How the User Interface (UI) Works

The apps are designed for everyday faculty and students with zero learning curve:

### Student Interface:
- **Guided Camera Outline:** During enrolment, students see a face guide with simple front/left/right/up/down cues and progress indicators. This is capture guidance, not identity or liveness verification.
- **Subjects and enrolment:** Students link an approved identity, join their subjects with a faculty join code and follow face-enrolment status.
- **Published history:** Students see only their own published results and their attendance percentage, which counts assessed classes only. They can raise a written query against their latest published Absent result.

### Faculty Interface:
- **Attendance dashboard:** The home screen shows overall, semester-wise and subject-wise attendance, a distribution chart, students below 75% and a downloadable semester report.
- **Controlled session opening:** The faculty member opens a scheduled or manually created session, which freezes the subject's approved roster for that session.
- **Camera Sweep:** A live 10-second sweep camera screen opens with an on-screen timer. Audio is muted automatically.
- **Interactive Review Sheet:** After processing, the roster shows clear color-coded statuses:
  - 🟢 **Proposed Present:** Corroborated model evidence that still requires a faculty decision.
  - 🟡 **Not recognized:** Processing worked but the student was not matched; the faculty member decides.
  - ⚪ **Unassessed:** Clearly flagged for the faculty member to mark *Present*, *Absent*, *Late*, or *Excused*.
- **Publish & Export:** The faculty member confirms every decision and publishes. Private PDF and CSV attendance sheets can then be downloaded.

### Admin Interface:
- **Guided setup:** Admins see a checklist (semester term, subjects, sections, subject allocations, faculty, assignments, students) that always names the next step, plus statistics and charts.
- **People and access:** Searchable faculty and student directories, login-account creation, and role and subject assignment without typing account IDs.

---

## 4. Deployment Cost Analysis (revised 25 October 2026)

Full workings, sources and assumptions are in [COST_AND_RELIABILITY.md](COST_AND_RELIABILITY.md). Provider prices were read on 25 October 2026 at **₹94.95 per US$**. Totals are infrastructure only. They exclude staff time, room cameras and the **model licence**, which is unpriced (see below). Availability figures are planning targets, not SLAs or measurements. FaceTrack has not yet demonstrated institute-scale throughput.

### Basis of these figures
- **No GPU.** The measured worker pipeline took 356 ms for a 12-frame clip on a CPU, and matching is limited to the students enrolled in that subject. A CPU server is sufficient at every scale below.
- **One server** runs the API, Redis and the recognition worker.
- **Maintenance staffing** is a support decision, not infrastructure, and is not included.
- **Hosting region.** An AWS Mumbai server keeps video in India and is cheaper than the European alternatives checked.

### Cost and reliability by institution size

| Scenario | Students | Sessions/day | Monthly (USD) | Monthly (INR) | Availability target | Notes |
|---|---|---|---|---|---|---|
| Demo | 20–50 | few | $0 | ₹0 | Demo only | Mac + free Supabase |
| Free pilot | up to ~100 | ~20 | $0 | ₹0 | 95–98% | Free Supabase allows 5 GB egress and pauses after a week idle, with no backups |
| Small paid | up to 1,000 | up to 120 | ≈ $44 | ≈ ₹4,200 | ≈ 99% | Supabase Pro + one 2 vCPU/4 GB server |
| Mid-sized college | 3,000 | 360 | ≈ $79 (HA ≈ $130) | ≈ ₹7,500 (₹12,300) | 99–99.5% (HA 99.9%) | Adds a 2-slot worker; HA needs a passed failover test |
| Large university | 10,000–20,000 | up to 2,400 | ≈ $220–290 | ≈ ₹20,900–27,500 | HA design + load test | Egress overage and more worker slots |


### How reliable is recognition?
- Teachers review and publish every result. A missed or uncertain face stays **Unassessed**; it is never marked absent automatically.
- The chosen model reports 95.02% on the IJB-C verification benchmark and 99.70% on LFW. These are controlled datasets. Small, dim or turned faces in a classroom are harder, and an independent study found ArcFace at 77.27% top-1 on a mixed-quality dataset.
- FaceTrack's own evidence so far is one real two-person capture in low light, where one of two students was recognised, and 1 of 6 independent test scenarios passed. **No classroom accuracy percentage can be promised yet.** A supervised pilot (at least 100 students, 30 sessions, 3 rooms or days) will produce the first defensible figure.

### Items that must be settled before paid rollout
1. **Model licence.** The detector and recognizer files are published for non-commercial research only. A commercial licence from InsightFace (price not published) or an alternative, re-evaluated model is required for institute use.
2. **Supabase Pro ($25/month)** before real enrolment, for backups, no inactivity pause and enough bandwidth.
3. **Measured clip size and processing time** on the chosen server, which replace the estimates in the table.

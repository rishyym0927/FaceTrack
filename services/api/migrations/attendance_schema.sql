CREATE TABLE app.sessions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL REFERENCES app.institutes(id),
 offering_id uuid NOT NULL, teacher_id uuid NOT NULL, starts_at timestamptz NOT NULL, ends_at timestamptz NOT NULL,
 room_label text NOT NULL DEFAULT '', occurrence_key text NOT NULL, status text NOT NULL DEFAULT 'scheduled'
 CHECK(status IN ('scheduled','open','closed','no_data','review_required','finalized','cancelled')),
 model_release_id uuid, recognition_profile_id uuid, policy_version text NOT NULL DEFAULT 'session-v1',
 roster_hash text, attendance_revision integer NOT NULL DEFAULT 0, version integer NOT NULL DEFAULT 1,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(ends_at>starts_at), UNIQUE(institute_id,id), UNIQUE(institute_id,occurrence_key),
 FOREIGN KEY(institute_id,offering_id) REFERENCES app.offerings(institute_id,id),
 FOREIGN KEY(institute_id,teacher_id) REFERENCES app.teachers(institute_id,id),
 FOREIGN KEY(institute_id,recognition_profile_id,model_release_id) REFERENCES app.recognition_profiles(institute_id,id,model_release_id));
ALTER TABLE app.template_sets ADD CONSTRAINT template_student_key UNIQUE(institute_id,id,student_id);
CREATE TABLE app.session_roster (
 institute_id uuid NOT NULL, session_id uuid NOT NULL, student_id uuid NOT NULL, name_snapshot text NOT NULL,
 enrollment_number_snapshot text NOT NULL, template_set_id uuid, template_epoch integer NOT NULL,
 recognition_eligible boolean NOT NULL, PRIMARY KEY(institute_id,session_id,student_id),
 CHECK(NOT recognition_eligible OR template_set_id IS NOT NULL),
 FOREIGN KEY(institute_id,session_id) REFERENCES app.sessions(institute_id,id),
 FOREIGN KEY(institute_id,student_id) REFERENCES app.students(institute_id,id),
 FOREIGN KEY(institute_id,template_set_id,student_id) REFERENCES app.template_sets(institute_id,id,student_id));
CREATE TABLE app.captures (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL, session_id uuid NOT NULL,
 asset_id uuid NOT NULL, submitted_by uuid NOT NULL REFERENCES auth.users(id),
 source_type text NOT NULL CHECK(source_type IN ('webcam','phone')), recorded_at timestamptz NOT NULL,
 status text NOT NULL DEFAULT 'awaiting_upload' CHECK(status IN ('awaiting_upload','queued','processing','review_required','failed','cancelled','expired')),
 generation integer NOT NULL DEFAULT 1, version integer NOT NULL DEFAULT 1, quality_json jsonb NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(institute_id,id), UNIQUE(institute_id,id,session_id), UNIQUE(asset_id),
 FOREIGN KEY(institute_id,session_id) REFERENCES app.sessions(institute_id,id),
 FOREIGN KEY(institute_id,asset_id) REFERENCES app.media_assets(institute_id,id));
ALTER TABLE app.media_assets DROP CONSTRAINT media_assets_purpose_check;
ALTER TABLE app.media_assets ADD CONSTRAINT media_assets_purpose_check CHECK(purpose IN ('enrollment','classroom'));
ALTER TABLE app.jobs DROP CONSTRAINT jobs_kind_check;
ALTER TABLE app.jobs ALTER COLUMN enrollment_attempt_id DROP NOT NULL;
ALTER TABLE app.jobs ADD COLUMN capture_id uuid;
ALTER TABLE app.jobs ADD CONSTRAINT jobs_capture_fk FOREIGN KEY(institute_id,capture_id) REFERENCES app.captures(institute_id,id);
ALTER TABLE app.jobs ADD CONSTRAINT jobs_resource_kind CHECK(
 (kind='enrollment' AND enrollment_attempt_id IS NOT NULL AND capture_id IS NULL) OR
 (kind='recognition' AND enrollment_attempt_id IS NULL AND capture_id IS NOT NULL));
CREATE TABLE app.recognition_evidence (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL, session_id uuid NOT NULL, capture_id uuid NOT NULL,
 student_id uuid NOT NULL, template_set_id uuid NOT NULL, template_epoch integer NOT NULL,
 accepted_hits integer NOT NULL CHECK(accepted_hits>=2), span_ms double precision NOT NULL CHECK(span_ms>=500),
 scores_json jsonb NOT NULL, job_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(institute_id,id,session_id,student_id), UNIQUE(institute_id,capture_id,student_id),
 FOREIGN KEY(institute_id,capture_id,session_id) REFERENCES app.captures(institute_id,id,session_id),
 FOREIGN KEY(institute_id,session_id,student_id) REFERENCES app.session_roster(institute_id,session_id,student_id),
 FOREIGN KEY(institute_id,template_set_id,student_id) REFERENCES app.template_sets(institute_id,id,student_id),
 FOREIGN KEY(institute_id,job_id) REFERENCES app.jobs(institute_id,id));
CREATE TABLE app.attendance_records (
 institute_id uuid NOT NULL, session_id uuid NOT NULL, student_id uuid NOT NULL,
 status text NOT NULL DEFAULT 'unassessed' CHECK(status IN ('unassessed','proposed_present','present','absent','late','excused')),
 source text NOT NULL DEFAULT 'none' CHECK(source IN ('none','ml','teacher')), evidence_id uuid, manual_lock boolean NOT NULL DEFAULT false,
 reason text, modified_by uuid REFERENCES auth.users(id), version integer NOT NULL DEFAULT 1,
 PRIMARY KEY(institute_id,session_id,student_id),
 FOREIGN KEY(institute_id,session_id,student_id) REFERENCES app.session_roster(institute_id,session_id,student_id),
 FOREIGN KEY(institute_id,evidence_id,session_id,student_id) REFERENCES app.recognition_evidence(institute_id,id,session_id,student_id));
CREATE TABLE app.publications (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL, session_id uuid NOT NULL, revision integer NOT NULL,
 snapshot_json jsonb NOT NULL, snapshot_hash text NOT NULL, published_by uuid NOT NULL REFERENCES auth.users(id),
 published_at timestamptz NOT NULL DEFAULT now(), reason text,
 UNIQUE(institute_id,id), UNIQUE(institute_id,session_id,revision),
 FOREIGN KEY(institute_id,session_id) REFERENCES app.sessions(institute_id,id));
CREATE INDEX session_dates ON app.sessions(institute_id,offering_id,starts_at);
CREATE INDEX capture_session ON app.captures(institute_id,session_id,status);
DO $$ DECLARE t text; r text; BEGIN
 FOREACH t IN ARRAY ARRAY['sessions','session_roster','captures','recognition_evidence','attendance_records','publications'] LOOP
 EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
 EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
 EXECUTE format('GRANT SELECT,INSERT ON app.%I TO facetrack_api',t);
 IF t<>'publications' THEN EXECUTE format('GRANT UPDATE ON app.%I TO facetrack_api',t); END IF;
 EXECUTE format('CREATE POLICY tenant_access ON app.%I USING(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker())) WITH CHECK(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker()))',t);
 END LOOP;
 FOR r IN SELECT rolname FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') LOOP
 EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA app FROM %I',r);
 END LOOP;
END $$;
CREATE POLICY recognition_worker_audit ON app.audit_events FOR INSERT WITH CHECK (
 institute_id=app.tenant_id() AND app.is_worker() AND actor_id IS NULL AND action IN ('capture.processed','capture.failed')
 AND resource_type='job' AND EXISTS(SELECT 1 FROM app.jobs j WHERE j.id=resource_id AND j.institute_id=app.tenant_id()
 AND j.lease_owner::text=summary->>'worker_id' AND j.kind='recognition'));

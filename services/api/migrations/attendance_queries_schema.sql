ALTER TABLE app.attendance_records DROP CONSTRAINT attendance_records_status_check;
ALTER TABLE app.attendance_records ADD CONSTRAINT attendance_records_status_check
 CHECK(status IN ('unassessed','proposed_present','proposed_absent','present','absent','late','excused'));
ALTER TABLE app.attendance_records ADD COLUMN assessment_code text;
ALTER TABLE app.attendance_records ADD COLUMN evidence_summary jsonb NOT NULL DEFAULT '{}';
ALTER TABLE app.attendance_records ADD CONSTRAINT attendance_records_assessment_code_check
 CHECK(assessment_code IS NULL OR assessment_code IN ('recognized','not_recognized','template_ineligible','limited_capture','processing_failed'));

ALTER TABLE app.publications ADD CONSTRAINT publications_identity_key
 UNIQUE(institute_id,id,session_id,revision);

CREATE TABLE app.attendance_disputes(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL,
 session_id uuid NOT NULL, student_id uuid NOT NULL, source_publication_id uuid NOT NULL,
 source_revision integer NOT NULL CHECK(source_revision>0), student_reason text NOT NULL CHECK(length(trim(student_reason)) BETWEEN 5 AND 1000),
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','accepted','rejected','withdrawn')),
 resolution_reason text, resolved_by uuid REFERENCES auth.users(id), resolved_at timestamptz,
 resolved_publication_id uuid, version integer NOT NULL DEFAULT 1 CHECK(version>0),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(institute_id,id),
 FOREIGN KEY(institute_id,session_id,student_id) REFERENCES app.session_roster(institute_id,session_id,student_id),
 FOREIGN KEY(institute_id,source_publication_id,session_id,source_revision)
  REFERENCES app.publications(institute_id,id,session_id,revision),
 FOREIGN KEY(institute_id,resolved_publication_id) REFERENCES app.publications(institute_id,id),
 CHECK((status='open' AND resolved_by IS NULL AND resolved_at IS NULL AND resolution_reason IS NULL AND resolved_publication_id IS NULL)
    OR (status='accepted' AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL AND resolution_reason IS NOT NULL AND resolved_publication_id IS NOT NULL)
    OR (status IN ('rejected','withdrawn') AND resolved_at IS NOT NULL AND resolution_reason IS NOT NULL AND resolved_publication_id IS NULL))
);
CREATE UNIQUE INDEX one_open_attendance_dispute
 ON app.attendance_disputes(institute_id,session_id,student_id,source_publication_id)
 WHERE status='open';
CREATE INDEX attendance_disputes_teacher_queue
 ON app.attendance_disputes(institute_id,status,created_at,id);

ALTER TABLE app.attendance_disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.attendance_disputes FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.attendance_disputes FROM PUBLIC;
GRANT SELECT,INSERT,UPDATE ON app.attendance_disputes TO facetrack_api;
CREATE POLICY tenant_access ON app.attendance_disputes
 USING(institute_id=app.tenant_id() AND app.is_member())
 WITH CHECK(institute_id=app.tenant_id() AND app.is_member());
DO $$ DECLARE r text; BEGIN
 FOR r IN SELECT rolname FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') LOOP
  EXECUTE format('REVOKE ALL ON app.attendance_disputes FROM %I',r);
 END LOOP;
END $$;

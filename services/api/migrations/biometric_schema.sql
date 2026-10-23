CREATE TABLE app.model_releases (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL REFERENCES app.institutes(id),
created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), version integer NOT NULL DEFAULT 1,
UNIQUE(institute_id,id),
manifest_json jsonb NOT NULL, manifest_hash text NOT NULL, license_status text NOT NULL CHECK(license_status='academic_local_only'), evaluation_status text NOT NULL DEFAULT 'incomplete', status text NOT NULL DEFAULT 'enabled' CHECK(status IN ('enabled','disabled')), UNIQUE(institute_id,manifest_hash));
CREATE TABLE app.recognition_profiles (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL REFERENCES app.institutes(id),
created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), version integer NOT NULL DEFAULT 1,
UNIQUE(institute_id,id),
model_release_id uuid NOT NULL, settings_json jsonb NOT NULL, settings_hash text NOT NULL, status text NOT NULL DEFAULT 'enabled' CHECK(status IN ('enabled','disabled')), FOREIGN KEY(institute_id,model_release_id) REFERENCES app.model_releases(institute_id,id), UNIQUE(institute_id,model_release_id,settings_hash), UNIQUE(institute_id,id,model_release_id));
CREATE TABLE app.consents (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL REFERENCES app.institutes(id),
created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), version integer NOT NULL DEFAULT 1,
UNIQUE(institute_id,id),
student_id uuid NOT NULL, notice_version text NOT NULL, notice_hash text NOT NULL, accepted_at timestamptz NOT NULL DEFAULT now(), withdrawn_at timestamptz, FOREIGN KEY(institute_id,student_id) REFERENCES app.students(institute_id,id), UNIQUE(institute_id,id,student_id));
CREATE TABLE app.media_assets (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL REFERENCES app.institutes(id),
created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), version integer NOT NULL DEFAULT 1,
UNIQUE(institute_id,id),
owner_user_id uuid NOT NULL REFERENCES auth.users(id), purpose text NOT NULL CHECK(purpose='enrollment'), bucket text NOT NULL, object_key text NOT NULL, mime_type text NOT NULL CHECK(mime_type IN ('video/mp4','video/webm')), expected_bytes bigint NOT NULL CHECK(expected_bytes BETWEEN 1 AND 26214400), byte_size bigint, sha256 text, expires_at timestamptz NOT NULL DEFAULT now()+interval '24 hours', reservation_expires_at timestamptz NOT NULL DEFAULT now()+interval '15 minutes', grant_expires_at timestamptz, deleted_at timestamptz, status text NOT NULL DEFAULT 'reserved' CHECK(status IN ('reserved','uploaded','delete_pending','deleted')), UNIQUE(bucket,object_key));
CREATE TABLE app.enrollment_attempts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL REFERENCES app.institutes(id),
created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), version integer NOT NULL DEFAULT 1,
UNIQUE(institute_id,id),
student_id uuid NOT NULL, consent_id uuid NOT NULL, asset_id uuid NOT NULL, model_release_id uuid NOT NULL, recognition_profile_id uuid NOT NULL, pose_order jsonb NOT NULL, challenge_hash text NOT NULL, status text NOT NULL DEFAULT 'awaiting_upload' CHECK(status IN ('awaiting_upload','queued','processing','review_required','active','failed','rejected','cancelled','expired')), generation integer NOT NULL DEFAULT 1 CHECK(generation>0), reviewed_by uuid REFERENCES auth.users(id), reason text, quality_json jsonb NOT NULL DEFAULT '{}', FOREIGN KEY(institute_id,student_id) REFERENCES app.students(institute_id,id), FOREIGN KEY(institute_id,consent_id,student_id) REFERENCES app.consents(institute_id,id,student_id), FOREIGN KEY(institute_id,asset_id) REFERENCES app.media_assets(institute_id,id), FOREIGN KEY(institute_id,recognition_profile_id,model_release_id) REFERENCES app.recognition_profiles(institute_id,id,model_release_id), UNIQUE(institute_id,id,student_id,model_release_id,recognition_profile_id), UNIQUE(asset_id));
CREATE TABLE app.worker_identities (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL REFERENCES app.institutes(id),
created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), version integer NOT NULL DEFAULT 1,
UNIQUE(institute_id,id),
token_hash text NOT NULL UNIQUE, allowed_kinds jsonb NOT NULL DEFAULT '["enrollment"]', allowed_model_hashes jsonb NOT NULL, status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','revoked')), expires_at timestamptz NOT NULL, last_seen_at timestamptz);
CREATE TABLE app.jobs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL REFERENCES app.institutes(id),
created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), version integer NOT NULL DEFAULT 1,
UNIQUE(institute_id,id),
kind text NOT NULL CHECK(kind='enrollment'), enrollment_attempt_id uuid NOT NULL, generation integer NOT NULL DEFAULT 1, dedup_key text NOT NULL, state text NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','leased','running','retry_wait','succeeded','failed','cancelled')), stage text NOT NULL DEFAULT 'queued', attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 3), available_at timestamptz NOT NULL DEFAULT now(), lease_owner uuid, lease_epoch integer NOT NULL DEFAULT 0, lease_expires_at timestamptz, result_hash text, error_code text, FOREIGN KEY(institute_id,enrollment_attempt_id) REFERENCES app.enrollment_attempts(institute_id,id), FOREIGN KEY(institute_id,lease_owner) REFERENCES app.worker_identities(institute_id,id), UNIQUE(institute_id,dedup_key));
CREATE TABLE app.template_sets (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL REFERENCES app.institutes(id),
created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), version integer NOT NULL DEFAULT 1,
UNIQUE(institute_id,id),
student_id uuid NOT NULL, attempt_id uuid NOT NULL, model_release_id uuid NOT NULL, recognition_profile_id uuid NOT NULL, status text NOT NULL DEFAULT 'review_required' CHECK(status IN ('review_required','active','revoked','rejected')), activated_at timestamptz, revoked_at timestamptz, set_version integer NOT NULL DEFAULT 1, FOREIGN KEY(institute_id,attempt_id,student_id,model_release_id,recognition_profile_id) REFERENCES app.enrollment_attempts(institute_id,id,student_id,model_release_id,recognition_profile_id), UNIQUE(attempt_id));
CREATE TABLE app.face_templates (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), institute_id uuid NOT NULL REFERENCES app.institutes(id),
created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), version integer NOT NULL DEFAULT 1,
UNIQUE(institute_id,id),
template_set_id uuid NOT NULL, pose text NOT NULL DEFAULT 'unverified' CHECK(pose='unverified'), ordinal integer NOT NULL CHECK(ordinal BETWEEN 0 AND 4), ciphertext bytea NOT NULL, nonce bytea NOT NULL CHECK(octet_length(nonce)=12), key_id text NOT NULL, dimension integer NOT NULL CHECK(dimension=512), preprocess_version text NOT NULL, FOREIGN KEY(institute_id,template_set_id) REFERENCES app.template_sets(institute_id,id), UNIQUE(institute_id,template_set_id,ordinal), UNIQUE(key_id,nonce));
CREATE UNIQUE INDEX one_unfinished_enrollment ON app.enrollment_attempts(institute_id,student_id) WHERE status IN ('awaiting_upload','queued','processing','review_required');
CREATE UNIQUE INDEX one_active_template_set ON app.template_sets(institute_id,student_id,model_release_id) WHERE status='active';
CREATE INDEX job_claim ON app.jobs(institute_id,state,available_at);
CREATE INDEX media_expiry ON app.media_assets(expires_at);
CREATE INDEX biometric_review ON app.enrollment_attempts(institute_id,status,student_id);
CREATE FUNCTION app.is_worker() RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER
SET search_path=pg_catalog,app AS $$ SELECT EXISTS(SELECT 1 FROM app.worker_identities WHERE
institute_id=app.tenant_id() AND token_hash=current_setting('app.worker_token_hash',true)
AND status='active' AND expires_at>now()) $$;
REVOKE ALL ON FUNCTION app.is_worker() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.is_worker() TO facetrack_api;
ALTER TABLE app.model_releases ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.model_releases FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.model_releases FROM PUBLIC;
GRANT SELECT ON app.model_releases TO facetrack_api;
CREATE POLICY biometric_tenant ON app.model_releases USING(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker())) WITH CHECK(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker()));
ALTER TABLE app.recognition_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.recognition_profiles FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.recognition_profiles FROM PUBLIC;
GRANT SELECT ON app.recognition_profiles TO facetrack_api;
CREATE POLICY biometric_tenant ON app.recognition_profiles USING(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker())) WITH CHECK(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker()));
ALTER TABLE app.consents ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.consents FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.consents FROM PUBLIC;
GRANT SELECT ON app.consents TO facetrack_api;
CREATE POLICY biometric_tenant ON app.consents USING(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker())) WITH CHECK(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker()));
GRANT INSERT,UPDATE ON app.consents TO facetrack_api;
ALTER TABLE app.media_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.media_assets FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.media_assets FROM PUBLIC;
GRANT SELECT ON app.media_assets TO facetrack_api;
CREATE POLICY biometric_tenant ON app.media_assets USING(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker())) WITH CHECK(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker()));
GRANT INSERT,UPDATE ON app.media_assets TO facetrack_api;
ALTER TABLE app.enrollment_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.enrollment_attempts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.enrollment_attempts FROM PUBLIC;
GRANT SELECT ON app.enrollment_attempts TO facetrack_api;
CREATE POLICY biometric_tenant ON app.enrollment_attempts USING(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker())) WITH CHECK(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker()));
GRANT INSERT,UPDATE ON app.enrollment_attempts TO facetrack_api;
ALTER TABLE app.worker_identities ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.worker_identities FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.worker_identities FROM PUBLIC;
GRANT SELECT ON app.worker_identities TO facetrack_api;
CREATE POLICY worker_self ON app.worker_identities FOR SELECT USING (token_hash=current_setting('app.worker_token_hash',true) AND status='active' AND expires_at>now());
GRANT UPDATE(last_seen_at) ON app.worker_identities TO facetrack_api;
CREATE POLICY worker_touch ON app.worker_identities FOR UPDATE USING(token_hash=current_setting('app.worker_token_hash',true));
ALTER TABLE app.jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.jobs FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.jobs FROM PUBLIC;
GRANT SELECT ON app.jobs TO facetrack_api;
CREATE POLICY biometric_tenant ON app.jobs USING(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker())) WITH CHECK(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker()));
GRANT INSERT,UPDATE ON app.jobs TO facetrack_api;
ALTER TABLE app.template_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.template_sets FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.template_sets FROM PUBLIC;
GRANT SELECT ON app.template_sets TO facetrack_api;
CREATE POLICY biometric_tenant ON app.template_sets USING(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker())) WITH CHECK(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker()));
GRANT INSERT,UPDATE ON app.template_sets TO facetrack_api;
ALTER TABLE app.face_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.face_templates FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.face_templates FROM PUBLIC;
GRANT SELECT ON app.face_templates TO facetrack_api;
CREATE POLICY biometric_tenant ON app.face_templates USING(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker())) WITH CHECK(institute_id=app.tenant_id() AND (app.is_member() OR app.is_worker()));
GRANT INSERT,UPDATE ON app.face_templates TO facetrack_api;

GRANT DELETE ON app.face_templates TO facetrack_api;
CREATE POLICY worker_student_read ON app.students FOR SELECT USING (institute_id=app.tenant_id() AND app.is_worker());
CREATE FUNCTION app.biometric_student_active(s uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,app AS $$ SELECT (app.is_member() OR app.is_worker()) AND EXISTS(
 SELECT 1 FROM app.students st JOIN app.memberships m ON m.institute_id=st.institute_id AND m.auth_user_id=st.auth_user_id
 JOIN app.institutes i ON i.id=st.institute_id WHERE st.id=s AND st.institute_id=app.tenant_id() AND st.status='approved'
 AND m.role='student' AND m.status='active' AND i.status='active') $$;
CREATE FUNCTION app.bump_template_epoch(s uuid) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,app AS $$ DECLARE e integer; BEGIN
 IF NOT app.is_member() THEN RAISE EXCEPTION 'Active membership required'; END IF;
 UPDATE app.students SET template_epoch=template_epoch+1,version=version+1,updated_at=now()
 WHERE id=s AND institute_id=app.tenant_id() RETURNING template_epoch INTO e; RETURN e; END $$;
REVOKE ALL ON FUNCTION app.biometric_student_active(uuid),app.bump_template_epoch(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.biometric_student_active(uuid),app.bump_template_epoch(uuid) TO facetrack_api;
DO $$ DECLARE r text; BEGIN
 FOR r IN SELECT rolname FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') LOOP
 EXECUTE format('REVOKE ALL ON SCHEMA app FROM %I',r);
 EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA app FROM %I',r);
 EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM %I',r);
 END LOOP; END $$;

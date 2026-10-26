-- Administrative provisioning: academic structure, identities, roles.
-- All writes go through SECURITY DEFINER functions guarded by app.is_admin().
-- Portable across environments: works whether or not the owner role bypasses RLS,
-- because the functions satisfy explicit admin policies rather than relying on bypass.

-- Admin predicate. Mirrors app.is_member(): read-only, invoker-scoped, reads only the
-- caller's own membership rows (visible via own_memberships), so it is NEVER referenced
-- by a memberships SELECT policy and cannot cause policy recursion.
CREATE FUNCTION app.is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = pg_catalog, app AS $$ SELECT EXISTS(
  SELECT 1 FROM app.memberships WHERE institute_id=app.tenant_id()
    AND auth_user_id=app.actor_id() AND role='admin' AND status='active') $$;
REVOKE ALL ON FUNCTION app.is_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.is_admin() TO facetrack_api;

-- Admin write policies (permissive; OR with existing policies). Each requires app.is_admin(),
-- so a non-admin member gains nothing. terms/courses/class_groups/offerings/offering_teachers
-- already carry a member-scoped FOR ALL policy, so the admin functions' inserts pass there;
-- the is_admin() guard inside each function is the actual gate for those tables.
-- teachers/students/memberships have no member write policy, so they need these.
CREATE POLICY admin_create ON app.teachers FOR INSERT
  WITH CHECK (institute_id=app.tenant_id() AND app.is_admin());
CREATE POLICY admin_modify ON app.teachers FOR UPDATE
  USING (institute_id=app.tenant_id() AND app.is_admin())
  WITH CHECK (institute_id=app.tenant_id() AND app.is_admin());
CREATE POLICY admin_create ON app.students FOR INSERT
  WITH CHECK (institute_id=app.tenant_id() AND app.is_admin());
CREATE POLICY admin_modify ON app.students FOR UPDATE
  USING (institute_id=app.tenant_id() AND app.is_admin())
  WITH CHECK (institute_id=app.tenant_id() AND app.is_admin());
CREATE POLICY admin_create ON app.memberships FOR INSERT
  WITH CHECK (institute_id=app.tenant_id() AND app.is_admin()
    AND role IN ('student','teacher','admin') AND status IN ('pending','active','suspended'));
CREATE POLICY admin_modify ON app.memberships FOR UPDATE
  USING (institute_id=app.tenant_id() AND app.is_admin())
  WITH CHECK (institute_id=app.tenant_id() AND app.is_admin());

-- Academic structure ---------------------------------------------------------
CREATE FUNCTION app.admin_create_term(p_code text, p_starts date, p_ends date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT app.is_admin() THEN RAISE EXCEPTION 'Administrator role required' USING ERRCODE='42501'; END IF;
  INSERT INTO app.terms(institute_id,code,starts_on,ends_on)
    VALUES(app.tenant_id(),p_code,p_starts,p_ends) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION app.admin_create_course(p_code text, p_title text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT app.is_admin() THEN RAISE EXCEPTION 'Administrator role required' USING ERRCODE='42501'; END IF;
  INSERT INTO app.courses(institute_id,code,title)
    VALUES(app.tenant_id(),p_code,p_title) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION app.admin_create_class_group(p_term_id uuid, p_branch text, p_semester integer, p_section text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT app.is_admin() THEN RAISE EXCEPTION 'Administrator role required' USING ERRCODE='42501'; END IF;
  INSERT INTO app.class_groups(institute_id,term_id,branch,semester,section)
    VALUES(app.tenant_id(),p_term_id,p_branch,p_semester,p_section) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Offering binds a course to a class group; its term is taken from the group so the
-- composite foreign key (institute,class_group,term) is always consistent.
CREATE FUNCTION app.admin_create_offering(p_course_id uuid, p_group_id uuid, p_title text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE v_id uuid; v_term uuid;
BEGIN
  IF NOT app.is_admin() THEN RAISE EXCEPTION 'Administrator role required' USING ERRCODE='42501'; END IF;
  SELECT term_id INTO v_term FROM app.class_groups
    WHERE institute_id=app.tenant_id() AND id=p_group_id;
  IF v_term IS NULL THEN RAISE EXCEPTION 'Class group not found' USING ERRCODE='23503'; END IF;
  INSERT INTO app.offerings(institute_id,term_id,course_id,class_group_id,title)
    VALUES(app.tenant_id(),v_term,p_course_id,p_group_id,p_title) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Identities ------------------------------------------------------------------
CREATE FUNCTION app.admin_create_teacher(p_number text, p_name text, p_email text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT app.is_admin() THEN RAISE EXCEPTION 'Administrator role required' USING ERRCODE='42501'; END IF;
  INSERT INTO app.teachers(institute_id,employee_number,official_name,official_email)
    VALUES(app.tenant_id(),p_number,p_name,lower(trim(p_email))) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION app.admin_create_student(p_number text, p_name text, p_email text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT app.is_admin() THEN RAISE EXCEPTION 'Administrator role required' USING ERRCODE='42501'; END IF;
  INSERT INTO app.students(institute_id,enrollment_number,official_name,official_email)
    VALUES(app.tenant_id(),p_number,p_name,lower(trim(p_email))) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Link an Auth account to an existing identity row (one-way; never unlinks).
CREATE FUNCTION app.admin_link_identity(p_kind text, p_identity_id uuid, p_auth_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE v_rows integer;
BEGIN
  IF NOT app.is_admin() THEN RAISE EXCEPTION 'Administrator role required' USING ERRCODE='42501'; END IF;
  IF p_kind='teacher' THEN
    UPDATE app.teachers SET auth_user_id=p_auth_user_id,updated_at=now(),version=version+1
      WHERE institute_id=app.tenant_id() AND id=p_identity_id;
  ELSIF p_kind='student' THEN
    UPDATE app.students SET auth_user_id=p_auth_user_id,updated_at=now(),version=version+1
      WHERE institute_id=app.tenant_id() AND id=p_identity_id;
  ELSE
    RAISE EXCEPTION 'Unknown identity kind' USING ERRCODE='22023';
  END IF;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows=0 THEN RAISE EXCEPTION 'Identity not found' USING ERRCODE='23503'; END IF;
END $$;

-- Roles -----------------------------------------------------------------------
CREATE FUNCTION app.admin_set_role(p_auth_user_id uuid, p_role text, p_status text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT app.is_admin() THEN RAISE EXCEPTION 'Administrator role required' USING ERRCODE='42501'; END IF;
  INSERT INTO app.memberships(institute_id,auth_user_id,role,status)
    VALUES(app.tenant_id(),p_auth_user_id,p_role,coalesce(nullif(trim(p_status),''),'active'))
    ON CONFLICT(institute_id,auth_user_id,role)
    DO UPDATE SET status=excluded.status,updated_at=now(),version=app.memberships.version+1
    RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Teacher assignment. The existing active_teacher trigger still enforces that the
-- teacher holds an active teacher membership, so assignment fails cleanly otherwise.
CREATE FUNCTION app.admin_assign_teacher(p_offering_id uuid, p_teacher_id uuid, p_can_finalize boolean)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT app.is_admin() THEN RAISE EXCEPTION 'Administrator role required' USING ERRCODE='42501'; END IF;
  INSERT INTO app.offering_teachers(institute_id,offering_id,teacher_id,can_finalize)
    VALUES(app.tenant_id(),p_offering_id,p_teacher_id,coalesce(p_can_finalize,true))
    ON CONFLICT(institute_id,offering_id,teacher_id)
    DO UPDATE SET status='active',can_finalize=excluded.can_finalize,
      updated_at=now(),version=app.offering_teachers.version+1
    RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Restrict EXECUTE to the runtime role only; deny PUBLIC and the Supabase roles.
DO $$ DECLARE f text; r text; BEGIN
  FOR f IN SELECT p.oid::regprocedure::text FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='app' AND p.proname LIKE 'admin\_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO facetrack_api', f);
    FOR r IN SELECT rolname FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') LOOP
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
    END LOOP;
  END LOOP;
  FOR r IN SELECT rolname FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION app.is_admin() FROM %I', r);
  END LOOP;
END $$;

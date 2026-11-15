CREATE FUNCTION app.admin_edit_academic(p_kind text, p_id uuid, p_version integer, p_fields jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
DECLARE
  v_institute uuid := app.tenant_id();
  v_current integer;
  v_result jsonb;
  v_start date;
  v_end date;
BEGIN
  IF NOT app.is_admin() OR NOT EXISTS (
    SELECT 1 FROM app.institutes WHERE id = v_institute AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'Active administrator role required' USING ERRCODE='42501';
  END IF;
  -- Match the timetable commit lock before taking any row locks.
  PERFORM pg_advisory_xact_lock(hashtextextended('schedule:' || v_institute::text, 0));

  CASE p_kind
    WHEN 'courses' THEN
      SELECT version INTO v_current FROM app.courses WHERE institute_id=v_institute AND id=p_id FOR UPDATE;
    WHEN 'offerings' THEN
      SELECT version INTO v_current FROM app.offerings WHERE institute_id=v_institute AND id=p_id FOR UPDATE;
    WHEN 'terms' THEN
      SELECT version INTO v_current FROM app.terms WHERE institute_id=v_institute AND id=p_id FOR UPDATE;
    WHEN 'class-groups' THEN
      SELECT version INTO v_current FROM app.class_groups WHERE institute_id=v_institute AND id=p_id FOR UPDATE;
    ELSE
      RAISE EXCEPTION 'Unsupported academic record' USING ERRCODE='22023';
  END CASE;
  IF v_current IS NULL THEN RETURN '{"error":"missing"}'::jsonb; END IF;
  IF v_current IS DISTINCT FROM p_version THEN RETURN '{"error":"stale"}'::jsonb; END IF;

  CASE p_kind
    WHEN 'courses' THEN
      IF nullif(btrim(p_fields->>'code'),'') IS NULL OR nullif(btrim(p_fields->>'title'),'') IS NULL THEN
        RETURN '{"error":"invalid"}'::jsonb;
      END IF;
      UPDATE app.terms t SET schedule_revision=t.schedule_revision+1
      WHERE t.institute_id=v_institute AND EXISTS (
        SELECT 1 FROM app.offerings o JOIN app.courses c
          ON (c.institute_id,c.id)=(o.institute_id,o.course_id)
        WHERE (o.institute_id,o.term_id)=(t.institute_id,t.id)
          AND c.id=p_id AND c.code IS DISTINCT FROM btrim(p_fields->>'code')
      );
      UPDATE app.courses c SET code=btrim(p_fields->>'code'),title=btrim(p_fields->>'title'),
        updated_at=now(),version=c.version+1
      WHERE c.institute_id=v_institute AND c.id=p_id
      RETURNING jsonb_build_object('id',c.id,'version',c.version) INTO v_result;
    WHEN 'offerings' THEN
      IF nullif(btrim(p_fields->>'title'),'') IS NULL THEN RETURN '{"error":"invalid"}'::jsonb; END IF;
      UPDATE app.offerings o SET title=btrim(p_fields->>'title'),updated_at=now(),version=o.version+1
      WHERE o.institute_id=v_institute AND o.id=p_id
      RETURNING jsonb_build_object('id',o.id,'version',o.version) INTO v_result;
    WHEN 'terms' THEN
      v_start := CAST(p_fields->>'starts_on' AS date);
      v_end := CAST(p_fields->>'ends_on' AS date);
      IF nullif(btrim(p_fields->>'code'),'') IS NULL OR v_start IS NULL OR v_end IS NULL OR v_end<v_start THEN
        RETURN '{"error":"invalid"}'::jsonb;
      END IF;
      IF EXISTS (
        SELECT 1 FROM app.terms t WHERE t.institute_id=v_institute AND t.id=p_id
          AND (v_start>t.starts_on OR v_end<t.ends_on)
      ) AND (
        EXISTS (
          SELECT 1 FROM app.schedule_series WHERE institute_id=v_institute AND term_id=p_id
            AND status='active' AND (effective_from<v_start OR effective_until>v_end)
        ) OR EXISTS (
          SELECT 1 FROM app.sessions s JOIN app.offerings o
            ON (o.institute_id,o.id)=(s.institute_id,s.offering_id)
          WHERE s.institute_id=v_institute AND o.term_id=p_id AND s.status<>'cancelled'
            AND ((s.starts_at AT TIME ZONE 'Asia/Kolkata')::date<v_start
              OR (s.ends_at AT TIME ZONE 'Asia/Kolkata')::date>v_end)
        )
      ) THEN RETURN '{"error":"schedule"}'::jsonb; END IF;
      UPDATE app.terms t SET code=btrim(p_fields->>'code'),starts_on=v_start,ends_on=v_end,
        schedule_revision=t.schedule_revision+CASE
          WHEN (t.code,t.starts_on,t.ends_on) IS DISTINCT FROM (btrim(p_fields->>'code'),v_start,v_end)
          THEN 1 ELSE 0 END,
        updated_at=now(),version=t.version+1
      WHERE t.institute_id=v_institute AND t.id=p_id
      RETURNING jsonb_build_object('id',t.id,'version',t.version) INTO v_result;
    WHEN 'class-groups' THEN
      IF p_fields->>'semester' IS NULL THEN RETURN '{"error":"invalid"}'::jsonb; END IF;
      UPDATE app.terms t SET schedule_revision=t.schedule_revision+1
      WHERE t.institute_id=v_institute AND EXISTS (
        SELECT 1 FROM app.class_groups g
        WHERE (g.institute_id,g.term_id)=(t.institute_id,t.id) AND g.id=p_id
          AND g.semester IS DISTINCT FROM CAST(p_fields->>'semester' AS integer)
      );
      UPDATE app.class_groups g SET semester=CAST(p_fields->>'semester' AS integer),
        updated_at=now(),version=g.version+1
      WHERE g.institute_id=v_institute AND g.id=p_id
      RETURNING jsonb_build_object('id',g.id,'version',g.version) INTO v_result;
  END CASE;
  RETURN v_result;
END $$;

REVOKE ALL ON FUNCTION app.admin_edit_academic(text,uuid,integer,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.admin_edit_academic(text,uuid,integer,jsonb) TO facetrack_api;
DO $$ DECLARE r text; BEGIN
  FOR r IN SELECT rolname FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION app.admin_edit_academic(text,uuid,integer,jsonb) FROM %I',r);
  END LOOP;
END $$;

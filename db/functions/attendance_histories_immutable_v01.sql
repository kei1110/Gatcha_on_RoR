CREATE OR REPLACE FUNCTION attendance_histories_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- OLD を参照しないため UPDATE/DELETE/TRUNCATE で共用できる（TRUNCATE は OLD 不在）
  RAISE EXCEPTION 'attendance_histories is append-only; % is blocked (SPEC 4.14, 5-year legal trail)', TG_OP
    USING ERRCODE = 'restrict_violation';
END;
$$;

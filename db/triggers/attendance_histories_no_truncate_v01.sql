-- 行トリガーがすり抜ける TRUNCATE を文トリガーで塞ぐ
CREATE TRIGGER attendance_histories_no_truncate
  BEFORE TRUNCATE ON attendance_histories
  FOR EACH STATEMENT
  EXECUTE FUNCTION attendance_histories_immutable();

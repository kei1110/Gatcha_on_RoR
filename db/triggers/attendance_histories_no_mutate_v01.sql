-- INSERT は append のため意図的に非対象（後続スライスが OR INSERT を足すと全 writer が死ぬ）
CREATE TRIGGER attendance_histories_no_mutate
  BEFORE UPDATE OR DELETE ON attendance_histories
  FOR EACH ROW
  EXECUTE FUNCTION attendance_histories_immutable();

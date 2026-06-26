# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_26_021532) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "btree_gist"
  enable_extension "pg_catalog.plpgsql"

  create_table "approval_assignments", force: :cascade do |t|
    t.timestamptz "acted_at"
    t.bigint "approvable_id", null: false
    t.string "approvable_type", null: false
    t.bigint "approver_id", null: false
    t.text "comment"
    t.datetime "created_at", null: false
    t.integer "decision", default: 0, null: false
    t.bigint "organization_id", null: false
    t.integer "position", null: false
    t.integer "purpose", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["approvable_type", "approvable_id"], name: "index_approval_assignments_on_approvable"
    t.index ["organization_id", "approvable_type", "approvable_id", "purpose", "position"], name: "index_approval_assignments_unique_stage", unique: true
    t.index ["organization_id", "approver_id", "decision"], name: "index_approval_assignments_on_approver"
    t.index ["organization_id"], name: "index_approval_assignments_on_organization_id"
  end

  create_table "approval_test_records", force: :cascade do |t|
    t.integer "approval_status", default: 0, null: false
    t.datetime "created_at", null: false
    t.bigint "organization_id", null: false
    t.bigint "requester_id", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_approval_test_records_on_organization_id"
    t.index ["requester_id"], name: "index_approval_test_records_on_requester_id"
  end

  create_table "attendance_histories", force: :cascade do |t|
    t.bigint "actor_id"
    t.datetime "created_at", null: false
    t.date "event_date", null: false
    t.integer "event_type", null: false
    t.timestamptz "new_clock_in"
    t.timestamptz "new_clock_out"
    t.integer "new_early_leave_minutes"
    t.boolean "new_is_early_leave"
    t.boolean "new_is_late"
    t.integer "new_late_minutes"
    t.integer "new_status"
    t.text "note"
    t.bigint "organization_id", null: false
    t.timestamptz "previous_clock_in"
    t.timestamptz "previous_clock_out"
    t.integer "previous_early_leave_minutes"
    t.boolean "previous_is_early_leave"
    t.boolean "previous_is_late"
    t.integer "previous_late_minutes"
    t.integer "previous_status"
    t.bigint "source_id"
    t.string "source_type"
    t.bigint "user_id", null: false
    t.index ["organization_id", "actor_id"], name: "idx_ah_actor"
    t.index ["organization_id", "source_type", "source_id"], name: "idx_ah_source"
    t.index ["organization_id", "user_id", "event_date"], name: "idx_ah_user_event_date"
    t.index ["organization_id"], name: "index_attendance_histories_on_organization_id"
  end

  create_table "attendance_records", force: :cascade do |t|
    t.decimal "actual_work_hours", precision: 6, scale: 2
    t.timestamptz "clock_in"
    t.timestamptz "clock_out"
    t.datetime "created_at", null: false
    t.decimal "deep_night_hours", precision: 6, scale: 2
    t.integer "early_leave_minutes"
    t.boolean "is_early_leave"
    t.boolean "is_holiday_work", default: false, null: false
    t.boolean "is_late"
    t.integer "late_minutes"
    t.bigint "leave_type_id"
    t.decimal "legal_overtime_hours", precision: 6, scale: 2
    t.text "note"
    t.bigint "organization_id", null: false
    t.integer "proxy_clock_reason"
    t.decimal "scheduled_overtime_hours", precision: 6, scale: 2
    t.integer "status", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.date "work_date", null: false
    t.bigint "work_pattern_id"
    t.index ["organization_id", "id"], name: "index_attendance_records_on_organization_id_and_id", unique: true
    t.index ["organization_id"], name: "index_attendance_records_on_organization_id"
    t.index ["user_id", "work_date"], name: "index_attendance_records_on_user_id_and_work_date", unique: true
    t.check_constraint "leave_type_id IS NULL OR (status = ANY (ARRAY[2, 3, 4]))", name: "attendance_records_leave_type_only_on_leave_status"
  end

  create_table "clock_change_requests", force: :cascade do |t|
    t.integer "approval_status", default: 0, null: false
    t.bigint "attendance_record_id"
    t.integer "change_type", null: false
    t.datetime "created_at", null: false
    t.date "last_stale_notified_on"
    t.timestamptz "new_clock_in"
    t.timestamptz "new_clock_out"
    t.bigint "organization_id", null: false
    t.timestamptz "original_clock_in"
    t.timestamptz "original_clock_out"
    t.text "reason"
    t.bigint "requester_id", null: false
    t.date "target_date"
    t.datetime "updated_at", null: false
    t.text "withdrawal_reason"
    t.index ["organization_id", "id"], name: "index_clock_change_requests_on_organization_id_and_id", unique: true
    t.index ["organization_id", "requester_id", "approval_status"], name: "idx_ccr_requester_status"
    t.index ["organization_id"], name: "index_clock_change_requests_on_organization_id"
  end

  create_table "company_calendars", force: :cascade do |t|
    t.boolean "counts_as_paid_leave", default: false, null: false
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.integer "day_type", null: false
    t.string "fiscal_year", null: false
    t.string "name"
    t.bigint "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "date"], name: "index_company_calendars_on_organization_id_and_date", unique: true
    t.index ["organization_id", "id"], name: "index_company_calendars_on_organization_id_and_id", unique: true
    t.index ["organization_id"], name: "index_company_calendars_on_organization_id"
  end

  create_table "holiday_work_requests", force: :cascade do |t|
    t.integer "approval_status", default: 0, null: false
    t.bigint "compensation_leave_type_id", null: false
    t.datetime "created_at", null: false
    t.bigint "organization_id", null: false
    t.text "reason"
    t.bigint "requester_id", null: false
    t.datetime "updated_at", null: false
    t.date "work_date", null: false
    t.index ["organization_id", "id"], name: "index_holiday_work_requests_on_organization_id_and_id", unique: true
    t.index ["organization_id", "requester_id", "approval_status"], name: "idx_hwr_requester_status"
    t.index ["organization_id", "requester_id", "work_date"], name: "idx_hwr_active_unique", unique: true, where: "(approval_status = ANY (ARRAY[0, 1]))"
    t.index ["organization_id"], name: "index_holiday_work_requests_on_organization_id"
  end

  create_table "leave_balances", force: :cascade do |t|
    t.decimal "carry_over_days", precision: 6, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.string "fiscal_year", null: false
    t.decimal "granted_days", precision: 6, scale: 2, default: "0.0", null: false
    t.date "granted_on"
    t.bigint "leave_type_id", null: false
    t.bigint "organization_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "used_days", precision: 6, scale: 2, default: "0.0", null: false
    t.bigint "user_id", null: false
    t.index ["organization_id", "id"], name: "index_leave_balances_on_organization_id_and_id", unique: true
    t.index ["organization_id", "user_id", "leave_type_id", "fiscal_year"], name: "index_leave_balances_unique", unique: true
    t.index ["organization_id", "user_id"], name: "index_leave_balances_on_organization_id_and_user_id"
    t.index ["organization_id"], name: "index_leave_balances_on_organization_id"
  end

  create_table "leave_requests", force: :cascade do |t|
    t.integer "approval_status", default: 0, null: false
    t.datetime "created_at", null: false
    t.decimal "days_requested", precision: 6, scale: 2, null: false
    t.date "end_date", null: false
    t.integer "half_day_type", default: 0, null: false
    t.bigint "leave_type_id", null: false
    t.bigint "organization_id", null: false
    t.text "reason"
    t.bigint "requester_id", null: false
    t.date "start_date", null: false
    t.datetime "updated_at", null: false
    t.text "withdrawal_reason"
    t.index ["organization_id", "id"], name: "index_leave_requests_on_organization_id_and_id", unique: true
    t.index ["organization_id", "requester_id", "approval_status"], name: "idx_on_organization_id_requester_id_approval_status_1501b5b67c"
    t.index ["organization_id", "requester_id", "leave_type_id", "start_date"], name: "idx_on_organization_id_requester_id_leave_type_id_s_b5292a3d17"
    t.index ["organization_id"], name: "index_leave_requests_on_organization_id"
  end

  create_table "leave_types", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "allow_half_day", default: false, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.boolean "paid_leave", default: false, null: false
    t.integer "system_type", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "id"], name: "index_leave_types_on_organization_id_and_id", unique: true
    t.index ["organization_id", "name"], name: "index_leave_types_on_organization_id_and_name", unique: true
    t.index ["organization_id"], name: "index_leave_types_on_organization_id"
  end

  create_table "monthly_attendance_summaries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "deferral_reason"
    t.integer "early_leave_days", default: 0, null: false
    t.decimal "holiday_work_hours", precision: 7, scale: 2, default: "0.0", null: false
    t.integer "late_days", default: 0, null: false
    t.bigint "organization_id", null: false
    t.decimal "overtime_hours_over_60", precision: 7, scale: 2, default: "0.0", null: false
    t.decimal "paid_leave_days_used", precision: 6, scale: 2, default: "0.0", null: false
    t.integer "scheduled_work_days", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.decimal "total_deep_night_hours", precision: 7, scale: 2, default: "0.0", null: false
    t.decimal "total_leave_hours", precision: 7, scale: 2, default: "0.0", null: false
    t.decimal "total_overtime_hours", precision: 7, scale: 2, default: "0.0", null: false
    t.decimal "total_work_hours", precision: 7, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.integer "work_days", default: 0, null: false
    t.string "year_month", null: false
    t.index ["organization_id", "id"], name: "index_monthly_summaries_org_id", unique: true
    t.index ["organization_id", "user_id", "year_month"], name: "index_monthly_summaries_unique", unique: true
    t.index ["organization_id", "user_id"], name: "index_monthly_summaries_org_user"
    t.index ["organization_id"], name: "index_monthly_attendance_summaries_on_organization_id"
  end

  create_table "organization_settings", force: :cascade do |t|
    t.integer "closing_day", default: 31, null: false
    t.datetime "created_at", null: false
    t.bigint "organization_id", null: false
    t.integer "submit_deadline_days", default: 5, null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "id"], name: "index_organization_settings_on_organization_id_and_id", unique: true
    t.index ["organization_id"], name: "index_organization_settings_on_organization_id", unique: true
  end

  create_table "organizations", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.integer "fiscal_year_end_month", default: 3, null: false
    t.string "name", null: false
    t.string "subdomain", null: false
    t.string "time_zone", default: "Asia/Tokyo", null: false
    t.datetime "updated_at", null: false
    t.index ["subdomain"], name: "index_organizations_on_subdomain", unique: true
  end

  create_table "reason_templates", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "applies_to", null: false
    t.datetime "created_at", null: false
    t.string "label", null: false
    t.bigint "organization_id", null: false
    t.string "template_text", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "id"], name: "index_reason_templates_on_organization_id_and_id", unique: true
    t.index ["organization_id", "label"], name: "index_reason_templates_on_organization_id_and_label", unique: true
    t.index ["organization_id"], name: "index_reason_templates_on_organization_id"
  end

  create_table "user_work_patterns", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.date "end_date"
    t.bigint "organization_id", null: false
    t.date "start_date", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "work_pattern_id", null: false
    t.index ["organization_id", "id"], name: "index_user_work_patterns_on_organization_id_and_id", unique: true
    t.index ["organization_id"], name: "index_user_work_patterns_on_organization_id"
    t.index ["user_id"], name: "index_user_work_patterns_on_user_id"
    t.index ["work_pattern_id"], name: "index_user_work_patterns_on_work_pattern_id"
    t.exclusion_constraint "organization_id WITH =, user_id WITH =, daterange(start_date, end_date, '[]'::text) WITH &&", where: "active", using: :gist, name: "user_work_patterns_no_overlap"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "current_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "email", null: false
    t.boolean "email_enabled", default: false, null: false
    t.string "employee_code", null: false
    t.string "encrypted_password", default: "", null: false
    t.boolean "exempt_from_overtime", default: false, null: false
    t.integer "failed_attempts", default: 0, null: false
    t.datetime "last_sign_in_at"
    t.string "last_sign_in_ip"
    t.datetime "locked_at"
    t.bigint "manager_id"
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.integer "role", default: 0, null: false
    t.integer "sign_in_count", default: 0, null: false
    t.string "unlock_token"
    t.datetime "updated_at", null: false
    t.index ["manager_id"], name: "index_users_on_manager_id"
    t.index ["organization_id", "email"], name: "index_users_on_organization_id_and_email", unique: true
    t.index ["organization_id", "employee_code"], name: "index_users_on_organization_id_and_employee_code", unique: true
    t.index ["organization_id", "id"], name: "index_users_on_organization_id_and_id", unique: true
    t.index ["organization_id"], name: "index_users_on_organization_id"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
  end

  create_table "work_patterns", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "afternoon_half_break_minutes"
    t.integer "break_minutes", null: false
    t.time "core_time_end"
    t.time "core_time_start"
    t.datetime "created_at", null: false
    t.time "end_time", null: false
    t.boolean "flextime", default: false, null: false
    t.integer "morning_half_break_minutes"
    t.string "name", null: false
    t.boolean "night_shift", default: false, null: false
    t.bigint "organization_id", null: false
    t.decimal "standard_work_hours", precision: 4, scale: 2, null: false
    t.time "start_time", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "id"], name: "index_work_patterns_on_organization_id_and_id", unique: true
    t.index ["organization_id", "name"], name: "index_work_patterns_on_organization_id_and_name", unique: true
    t.index ["organization_id"], name: "index_work_patterns_on_organization_id"
  end

  add_foreign_key "approval_assignments", "organizations"
  add_foreign_key "approval_assignments", "users", column: ["organization_id", "approver_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "attendance_histories", "organizations"
  add_foreign_key "attendance_histories", "users", column: ["organization_id", "actor_id"], primary_key: ["organization_id", "id"], name: "ah_actor_same_tenant"
  add_foreign_key "attendance_histories", "users", column: ["organization_id", "user_id"], primary_key: ["organization_id", "id"], name: "ah_user_same_tenant"
  add_foreign_key "attendance_records", "leave_types", column: ["organization_id", "leave_type_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "attendance_records", "organizations"
  add_foreign_key "attendance_records", "users", column: ["organization_id", "user_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "attendance_records", "work_patterns", column: ["organization_id", "work_pattern_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "clock_change_requests", "attendance_records", column: ["organization_id", "attendance_record_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "clock_change_requests", "organizations"
  add_foreign_key "clock_change_requests", "users", column: ["organization_id", "requester_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "company_calendars", "organizations"
  add_foreign_key "holiday_work_requests", "leave_types", column: ["organization_id", "compensation_leave_type_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "holiday_work_requests", "organizations"
  add_foreign_key "holiday_work_requests", "users", column: ["organization_id", "requester_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "leave_balances", "leave_types", column: ["organization_id", "leave_type_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "leave_balances", "organizations"
  add_foreign_key "leave_balances", "users", column: ["organization_id", "user_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "leave_requests", "leave_types", column: ["organization_id", "leave_type_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "leave_requests", "organizations"
  add_foreign_key "leave_requests", "users", column: ["organization_id", "requester_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "leave_types", "organizations"
  add_foreign_key "monthly_attendance_summaries", "organizations"
  add_foreign_key "monthly_attendance_summaries", "users", column: ["organization_id", "user_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "organization_settings", "organizations"
  add_foreign_key "reason_templates", "organizations"
  add_foreign_key "user_work_patterns", "organizations"
  add_foreign_key "user_work_patterns", "users", column: ["organization_id", "user_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "user_work_patterns", "work_patterns", column: ["organization_id", "work_pattern_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "users", "organizations"
  add_foreign_key "users", "users", column: ["organization_id", "manager_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "work_patterns", "organizations"

  create_function :attendance_histories_immutable, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.attendance_histories_immutable()
       RETURNS trigger
       LANGUAGE plpgsql
      AS $function$
      BEGIN
        -- OLD を参照しないため UPDATE/DELETE/TRUNCATE で共用できる（TRUNCATE は OLD 不在）
        RAISE EXCEPTION 'attendance_histories is append-only; % is blocked (SPEC 4.14, 5-year legal trail)', TG_OP
          USING ERRCODE = 'restrict_violation';
      END;
      $function$
  SQL

  create_trigger :attendance_histories_no_mutate, sql_definition: <<-SQL
      CREATE TRIGGER attendance_histories_no_mutate BEFORE DELETE OR UPDATE ON public.attendance_histories FOR EACH ROW EXECUTE FUNCTION attendance_histories_immutable()
  SQL

  create_trigger :attendance_histories_no_truncate, sql_definition: <<-SQL
      CREATE TRIGGER attendance_histories_no_truncate BEFORE TRUNCATE ON public.attendance_histories FOR EACH STATEMENT EXECUTE FUNCTION attendance_histories_immutable()
  SQL
end

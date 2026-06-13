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

ActiveRecord::Schema[8.1].define(version: 2026_06_13_010946) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "btree_gist"
  enable_extension "pg_catalog.plpgsql"

  create_table "attendance_records", force: :cascade do |t|
    t.decimal "actual_work_hours", precision: 6, scale: 2
    t.timestamptz "clock_in", null: false
    t.timestamptz "clock_out"
    t.datetime "created_at", null: false
    t.decimal "deep_night_hours", precision: 6, scale: 2
    t.integer "early_leave_minutes"
    t.boolean "is_early_leave"
    t.boolean "is_late"
    t.integer "late_minutes"
    t.decimal "legal_overtime_hours", precision: 6, scale: 2
    t.bigint "organization_id", null: false
    t.decimal "scheduled_overtime_hours", precision: 6, scale: 2
    t.integer "status", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.date "work_date", null: false
    t.bigint "work_pattern_id"
    t.index ["organization_id", "id"], name: "index_attendance_records_on_organization_id_and_id", unique: true
    t.index ["organization_id"], name: "index_attendance_records_on_organization_id"
    t.index ["user_id", "work_date"], name: "index_attendance_records_on_user_id_and_work_date", unique: true
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

  add_foreign_key "attendance_records", "organizations"
  add_foreign_key "attendance_records", "users", column: ["organization_id", "user_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "attendance_records", "work_patterns", column: ["organization_id", "work_pattern_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "company_calendars", "organizations"
  add_foreign_key "leave_types", "organizations"
  add_foreign_key "organization_settings", "organizations"
  add_foreign_key "reason_templates", "organizations"
  add_foreign_key "user_work_patterns", "organizations"
  add_foreign_key "user_work_patterns", "users", column: ["organization_id", "user_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "user_work_patterns", "work_patterns", column: ["organization_id", "work_pattern_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "users", "organizations"
  add_foreign_key "users", "users", column: ["organization_id", "manager_id"], primary_key: ["organization_id", "id"]
  add_foreign_key "work_patterns", "organizations"
end

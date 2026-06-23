# Phase 3-3b 月次サマリ・日別明細 CSV 出力 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** §6.4 の月次サマリ CSV（collection・全社員 1 行）と日別明細 CSV（member・個人 1 ヶ月・1 行=1 日）を、UTF-8 BOM + CRLF + RFC 4180 + formula-injection サニタイズでストリーミング DL できるようにする。

**Architecture:** 行生成を PORO exporter（`MonthlySummaries::Csv::SummaryExporter` / `DailyDetailExporter`）に分離し、型駆動のセル整形＋無害化を共有プリミティブ `MonthlySummaries::Csv::Row` に集約。controller は対象を `policy_scope` 起点で**事前 `.to_a` 確定**（テナント文脈下）してから Enumerator body をストリーム（DB を body で引かない＝テナント安全・mid-stream 破損なし）。3-3a の MonthlyAttendanceSummary 列（休暇 2 列含む）と AttendanceRecord を読むだけ。

**Tech Stack:** Rails 8.1 / Ruby 標準 `CSV` / RSpec / FactoryBot / Pundit / acts_as_tenant。

**設計典拠:** `docs/superpowers/specs/2026-06-23-phase-3-3-csv-design.md`（§5 CSV 出力層・§6 controller/routes/policy・§4 列マッピング・D7/D11/D12・多視点レビュー反映）。3-3a（AR `leave_type_id` / `LeaveAggregator` / MAS 休暇 2 列）は main にマージ済（PR #16）。

## Global Constraints

- **ブランチ:** `feat/phase3-3b-csv-export`（作成済）。コミット identity = kei1110 `<eoh2145@gmail.com>`。
- **frozen_string_literal:** 全 .rb 先頭に付与。
- **CSV 形式（§6.4・§16.1）:** UTF-8 **BOM**（先頭 `"﻿"` を 1 度）＋ **CRLF**（`CSV.generate_line(..., row_sep: "\r\n")`）＋ RFC 4180 quoting（Ruby 標準 `CSV` 委譲）。日付 `YYYY-MM-DD`・時刻 `HH:MM`・小数ドット（`BigDecimal#to_s("F")`）。
- **formula-injection サニタイズ（D12・RAILS_GOTCHAS）:** **文字列セル**で先頭が `= + - @` / TAB / CR のものは `'` 前置。**数値・日付・時刻セルはサニタイズしない**（負値の system 値は本 CSV に出現しないが、型で分岐し誤無害化を防ぐ）。
- **NULL → 空セル**（"0" 誤出力を避ける・休暇日は計算 8 列 NULL）。
- **社員識別子列（D11）:** 月次サマリ CSV 先頭に `employee_code`・`name`。`name` はユーザー入力由来ゆえ要サニタイズ。
- **scope（§3.4・§16）:** `summary_csv` は `policy_scope` 起点（生 where 禁止・manager=自分+部下／hr_admin=全社）。`detail_csv` は `set_summary`（`policy_scope.find`→scope 外 404・IDOR）。
- **テナント安全（D7）:** 対象行は action 内で `.to_a` 事前確定。Enumerator body は文字列整形＋`I18n.t` のみ（DB を引かない）。`ActsAsTenant.without_tenant` を出力経路で使わない。
- **TZ:** 保存済タイムスタンプは組織 TZ で整形（`value.in_time_zone(current_tenant.time_zone).strftime("%H:%M")`）。
- **完了条件:** `bundle exec rspec`・`bundle exec rubocop --force-exclusion <touched>`、app/ 変更ゆえ `bin/brakeman --no-pager`、views 変更ゆえ可能なら `bundle exec erb_lint`。`tenant-isolation-reviewer`（CSV・scope）、`/preflight` 後 PR。

---

## ファイル構成

- Create: `app/services/monthly_summaries/csv/row.rb` — BOM/CRLF/RFC4180 + 型駆動セル整形 + サニタイズの共有プリミティブ
- Create: `app/services/monthly_summaries/csv/summary_exporter.rb` — summary 群 → Enumerator<String>
- Create: `app/services/monthly_summaries/csv/daily_detail_exporter.rb` — AR 群 → Enumerator<String>
- Modify: `config/locales/ja.yml` / `config/locales/en.yml` — AR status ラベル（5 値）＋ CSV ヘッダ
- Modify: `config/routes.rb` — collection `summary_csv` / member `detail_csv`
- Modify: `app/controllers/monthly_attendance_summaries_controller.rb` — 2 action + `stream_csv` + `set_summary only:`
- Modify: `app/policies/monthly_attendance_summary_policy.rb` — `summary_csv?` / `detail_csv?`
- Modify: `app/views/monthly_attendance_summaries/index.html.erb` / `show.html.erb` — DL 導線
- Modify: `docs/SPEC.md` — §6.4 に社員コード・氏名列を追記（穴埋め）
- Test: `spec/services/monthly_summaries/csv/row_spec.rb`・`summary_exporter_spec.rb`・`daily_detail_exporter_spec.rb`（新）／`spec/requests/monthly_attendance_summaries_spec.rb`（追記）

---

### Task 1: `MonthlySummaries::Csv::Row`（共有プリミティブ）

**Files:**
- Create: `app/services/monthly_summaries/csv/row.rb`
- Test: `spec/services/monthly_summaries/csv/row_spec.rb`

**Interfaces:**
- Produces: `MonthlySummaries::Csv::Row::BOM`（`"﻿"`）／`Row.line(cells, time_zone: nil) → String`（CRLF 終端の 1 行・型駆動整形＋サニタイズ済）。

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/monthly_summaries/csv/row_spec.rb` を新規作成:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::Csv::Row do
  describe ".line" do
    it "RFC4180 + CRLF 終端で 1 行を生成" do
      expect(described_class.line(%w[a b])).to eq("a,b\r\n")
    end

    it "カンマ・引用符を含む文字列を quoting" do
      expect(described_class.line(["a,b", 'q"x'])).to eq(%("a,b","q""x"\r\n))
    end

    it "nil は空セル" do
      expect(described_class.line([nil, "x"])).to eq(",x\r\n")
    end

    it "BigDecimal はドット小数（科学記法にしない）" do
      expect(described_class.line([BigDecimal("8.0"), BigDecimal("0.5")])).to eq("8.0,0.5\r\n")
    end

    it "Integer はそのまま" do
      expect(described_class.line([3])).to eq("3\r\n")
    end

    it "Date は YYYY-MM-DD" do
      expect(described_class.line([Date.new(2026, 3, 5)])).to eq("2026-03-05\r\n")
    end

    it "Time は組織 TZ で HH:MM" do
      t = Time.utc(2026, 3, 5, 0, 30) # JST 09:30
      expect(described_class.line([t], time_zone: "Tokyo")).to eq("09:30\r\n")
    end

    it "formula-injection: 文字列先頭 = + - @ TAB は ' 前置で無害化" do
      expect(described_class.line(["=SUM(A1)"])).to eq(%("'=SUM(A1)"\r\n)) # ' 前置後も = 始まりでなくなるが quoting は CSV 判断
      expect(described_class.line(["+1"])).to eq("'+1\r\n")
      expect(described_class.line(["-cmd"])).to eq("'-cmd\r\n")
      expect(described_class.line(["@x"])).to eq("'@x\r\n")
      expect(described_class.line(["\tx"])).to eq("'\tx\r\n")
    end

    it "数値の負値はサニタイズしない（型で分岐）" do
      expect(described_class.line([BigDecimal("-1.5")])).to eq("-1.5\r\n")
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/monthly_summaries/csv/row_spec.rb`
Expected: FAIL（`uninitialized constant MonthlySummaries::Csv::Row`）

- [ ] **Step 3: 実装**

`app/services/monthly_summaries/csv/row.rb` を新規作成:

```ruby
# frozen_string_literal: true

require "csv"
require "bigdecimal"

module MonthlySummaries
  module Csv
    # CSV 行生成の共有プリミティブ（SPEC §5・3-3 設計 D12）。
    # 型駆動でセルを整形し、文字列セルのみ formula-injection を無害化する。
    module Row
      BOM = "﻿"
      # スプレッドシートインジェクション: 先頭が = + - @ / TAB / CR の文字列は数式・コマンド評価され得る。
      DANGEROUS_PREFIX = /\A[=+\-@\t\r]/

      module_function

      # 1 行を CRLF 終端・RFC4180 quoting で生成（型駆動・time_zone は Time 整形に使用）
      def line(cells, time_zone: nil)
        ::CSV.generate_line(cells.map { |c| cell(c, time_zone) }, row_sep: "\r\n")
      end

      def cell(value, time_zone = nil)
        case value
        when nil                                then nil  # CSV は nil→未引用空 / ""→引用空 "" ゆえ NULL は nil を返す（明細 CSV が未引用空に依存）
        when String                             then sanitize(value)
        when ActiveSupport::TimeWithZone, Time  then value.in_time_zone(time_zone).strftime("%H:%M")
        when Date                               then value.strftime("%Y-%m-%d")
        when BigDecimal                         then value.to_s("F") # ドット小数（科学記法回避）
        else value.to_s
        end
      end

      def sanitize(str)
        DANGEROUS_PREFIX.match?(str) ? "'#{str}" : str
      end
    end
  end
end
```

- [ ] **Step 4: テストを通す**

Run: `bundle exec rspec spec/services/monthly_summaries/csv/row_spec.rb`
Expected: PASS（全 example）

> 注: `'=SUM(A1)` は `'` 前置後も内部に `,` `=` を含まないため CSV は quoting しない可能性がある。Step 1 の該当 example が実出力と食い違ったら、実出力（`'=SUM(A1)\r\n` か `"'=SUM(A1)"\r\n`）に合わせて expected を修正してよい（`'` 前置による無害化が要点・quoting 有無は CSV 仕様任せ）。

- [ ] **Step 5: lint + コミット**

```bash
bundle exec rubocop --force-exclusion app/services/monthly_summaries/csv/row.rb spec/services/monthly_summaries/csv/row_spec.rb
git add app/services/monthly_summaries/csv/row.rb spec/services/monthly_summaries/csv/row_spec.rb
git commit -m "feat: Csv::Row（BOM/CRLF/RFC4180 + 型駆動整形 + formula-injection 無害化）"
```

---

### Task 2: `SummaryExporter`（月次サマリ CSV・社員識別子列）

**Files:**
- Create: `app/services/monthly_summaries/csv/summary_exporter.rb`
- Modify: `config/locales/ja.yml`・`config/locales/en.yml`（`monthly_summaries.csv.summary_headers`）
- Test: `spec/services/monthly_summaries/csv/summary_exporter_spec.rb`

**Interfaces:**
- Consumes: `MonthlySummaries::Csv::Row`（Task 1）。
- Produces: `SummaryExporter.call(summaries:) → Enumerator<String>`（summaries は `:user` preload 済の配列）。1 chunk 目 = BOM+ヘッダ、以降 1 summary = 1 行。

- [ ] **Step 1: i18n ヘッダを追加**

`config/locales/ja.yml` の末尾付近、トップレベル（`ja:` 直下・既存 `reason_templates:` 等と同階層）に追記:

```yaml
  monthly_summaries:
    csv:
      summary_headers: [社員コード, 氏名, 所定出勤日数, 実出勤日数, 総労働時間, 総残業, 60時間超残業, 法定休日労働, 深夜労働, 管理監督者, 有給使用日数, 遅刻回数, 早退回数, 総休暇時間]
      detail_headers: [日付, 出勤, 退勤, 実労働時間, 残業, 深夜, 遅刻分, 早退分, 状態]
```

`config/locales/en.yml` の同階層に英語版を追記（:en 文脈/フォールバック保険）:

```yaml
  monthly_summaries:
    csv:
      summary_headers: [employee_code, name, scheduled_days, work_days, total_work_hours, total_overtime, overtime_over_60, holiday_work, deep_night, exempt, paid_leave_days, late_count, early_leave_count, total_leave_hours]
      detail_headers: [date, clock_in, clock_out, actual_work, overtime, deep_night, late_min, early_leave_min, status]
```

- [ ] **Step 2: 失敗するテストを書く**

`spec/services/monthly_summaries/csv/summary_exporter_spec.rb` を新規作成:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::Csv::SummaryExporter do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def csv(summaries) = described_class.call(summaries: summaries).to_a.join

  it "BOM + ヘッダ行で始まる" do
    out = csv([])
    expect(out).to start_with("﻿社員コード,氏名,")
    expect(out).to end_with("総休暇時間\r\n")
  end

  it "1 summary = 1 行・列順と値（社員コード/氏名先頭・小数ドット・管理監督者 1/0）" do
    user = create(:user, employee_code: "E042", name: "山田太郎", exempt_from_overtime: true)
    s = create(:monthly_attendance_summary, user:, year_month: "2026-03",
               scheduled_work_days: 20, work_days: 18, total_work_hours: BigDecimal("144.0"),
               total_overtime_hours: BigDecimal("8.5"), overtime_hours_over_60: BigDecimal("0.0"),
               holiday_work_hours: BigDecimal("0.0"), total_deep_night_hours: BigDecimal("1.5"),
               late_days: 1, early_leave_days: 0,
               paid_leave_days_used: BigDecimal("1.5"), total_leave_hours: BigDecimal("12.0"))
    row = csv([s]).split("\r\n").last
    expect(row).to eq("E042,山田太郎,20,18,144.0,8.5,0.0,0.0,1.5,1,1.5,1,0,12.0")
  end

  it "氏名の formula-injection を無害化（先頭 = は ' 前置）" do
    user = create(:user, employee_code: "E001", name: "=cmd()")
    s = create(:monthly_attendance_summary, user:, year_month: "2026-03")
    expect(csv([s])).to include("E001,\"'=cmd()\",").or include("E001,'=cmd(),")
  end
end
```

- [ ] **Step 3: 失敗を確認**

Run: `bundle exec rspec spec/services/monthly_summaries/csv/summary_exporter_spec.rb`
Expected: FAIL（`uninitialized constant ...SummaryExporter`）

- [ ] **Step 4: 実装**

`app/services/monthly_summaries/csv/summary_exporter.rb` を新規作成:

```ruby
# frozen_string_literal: true

module MonthlySummaries
  module Csv
    # 月次サマリ CSV（§6.4・1 行=1 社員・給与システム入力用・3-3 設計 §4/§5）。
    # summaries は controller が policy_scope + includes(:user) で事前 .to_a した配列（body で DB を引かない）。
    class SummaryExporter
      def self.call(summaries:) = new(summaries:).call

      def initialize(summaries:)
        @summaries = summaries
      end

      def call
        Enumerator.new do |y|
          y << Row::BOM + Row.line(I18n.t("monthly_summaries.csv.summary_headers"))
          @summaries.each { |s| y << Row.line(row_for(s)) }
        end
      end

      private

      def row_for(summary)
        u = summary.user
        [
          u.employee_code, u.name,
          summary.scheduled_work_days, summary.work_days,
          summary.total_work_hours, summary.total_overtime_hours, summary.overtime_hours_over_60,
          summary.holiday_work_hours, summary.total_deep_night_hours,
          (u.exempt_from_overtime? ? "1" : "0"),
          summary.paid_leave_days_used, summary.late_days, summary.early_leave_days,
          summary.total_leave_hours
        ]
      end
    end
  end
end
```

- [ ] **Step 5: テストを通す**

Run: `bundle exec rspec spec/services/monthly_summaries/csv/summary_exporter_spec.rb`
Expected: PASS（食い違いは Task 1 注記同様、`'` 前置の無害化が満たされていれば quoting 有無に合わせて expected を調整）

- [ ] **Step 6: lint + コミット**

```bash
bundle exec rubocop --force-exclusion app/services/monthly_summaries/csv/summary_exporter.rb spec/services/monthly_summaries/csv/summary_exporter_spec.rb
git add app/services/monthly_summaries/csv/summary_exporter.rb spec/services/monthly_summaries/csv/summary_exporter_spec.rb config/locales/ja.yml config/locales/en.yml
git commit -m "feat: SummaryExporter（月次サマリ CSV・社員識別子列 + i18n ヘッダ）"
```

---

### Task 3: `DailyDetailExporter`（日別明細 CSV・AR status i18n）

**Files:**
- Create: `app/services/monthly_summaries/csv/daily_detail_exporter.rb`
- Modify: `config/locales/ja.yml`・`config/locales/en.yml`（`attendance_record.statuses.*`）
- Test: `spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb`

**Interfaces:**
- Consumes: `MonthlySummaries::Csv::Row`（Task 1）。
- Produces: `DailyDetailExporter.call(records:, time_zone:) → Enumerator<String>`（records は事前 `.to_a` 済 AR 配列・time_zone は組織 TZ 文字列）。1 行=1 AR。

- [ ] **Step 1: AR status i18n を追加**

`config/locales/ja.yml` の `attendance_record:`（既存・`status: 状態` や `proxy_clock_reasons:` がある block）に `statuses:` を追記:

```yaml
      attendance_record:
        work_date: 勤務日
        clock_in: 出勤時刻
        clock_out: 退勤時刻
        status: 状態
        statuses:
          working: 出勤中
          clocked_out: 退勤済
          morning_half: 午前半休
          afternoon_half: 午後半休
          on_leave: 全休
        proxy_clock_reasons:
          system_failure: システム障害
          unreachable: 連絡不能
          forgot_punch: 打刻忘れ
          other: その他
```

`config/locales/en.yml` の対応 `attendance_record:` block にも追記（無ければ作成）:

```yaml
        statuses:
          working: Working
          clocked_out: Clocked out
          morning_half: Morning half-day
          afternoon_half: Afternoon half-day
          on_leave: On leave
```

- [ ] **Step 2: 失敗するテストを書く**

`spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb` を新規作成:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::Csv::DailyDetailExporter do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:user) { create(:user) }

  def csv(records) = described_class.call(records: records, time_zone: "Tokyo").to_a.join

  it "BOM + ヘッダ行で始まる" do
    expect(csv([])).to start_with("﻿日付,出勤,退勤,")
  end

  it "出勤日: 日付/時刻(組織TZ)/実労働/残業/深夜/遅刻早退/状態" do
    rec = create(:attendance_record, user:, work_date: Date.new(2026, 3, 5), status: :clocked_out,
                 clock_in: Time.utc(2026, 3, 5, 0), clock_out: Time.utc(2026, 3, 5, 9),
                 actual_work_hours: BigDecimal("8.0"), legal_overtime_hours: BigDecimal("0.0"),
                 scheduled_overtime_hours: 0, deep_night_hours: BigDecimal("0.0"),
                 is_late: true, late_minutes: 15, is_early_leave: false, early_leave_minutes: 0)
    row = csv([rec]).split("\r\n").last
    expect(row).to eq("2026-03-05,09:00,18:00,8.0,0.0,0.0,15,0,退勤済")
  end

  it "全休日: 計算 8 列 NULL は空セル・状態は全休" do
    rec = create(:attendance_record, user:, work_date: Date.new(2026, 3, 6), status: :on_leave, clock_in: nil)
    row = csv([rec]).split("\r\n").last
    expect(row).to eq("2026-03-06,,,,,,,,全休")
  end
end
```

- [ ] **Step 3: 失敗を確認**

Run: `bundle exec rspec spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb`
Expected: FAIL（`uninitialized constant ...DailyDetailExporter`）

- [ ] **Step 4: 実装**

`app/services/monthly_summaries/csv/daily_detail_exporter.rb` を新規作成:

```ruby
# frozen_string_literal: true

module MonthlySummaries
  module Csv
    # 日別明細 CSV（§6.4・1 行=1 実在 AR・3-3 設計 §4/§5）。
    # records は controller が period.range で事前 .to_a した AR 配列・time_zone は組織 TZ。
    class DailyDetailExporter
      def self.call(records:, time_zone:) = new(records:, time_zone:).call

      def initialize(records:, time_zone:)
        @records = records
        @time_zone = time_zone
      end

      def call
        Enumerator.new do |y|
          y << Row::BOM + Row.line(I18n.t("monthly_summaries.csv.detail_headers"))
          @records.each { |r| y << Row.line(row_for(r), time_zone: @time_zone) }
        end
      end

      private

      def row_for(record)
        [
          record.work_date, record.clock_in, record.clock_out,
          record.actual_work_hours, record.legal_overtime_hours, record.deep_night_hours,
          record.late_minutes, record.early_leave_minutes,
          I18n.t("activerecord.attributes.attendance_record.statuses.#{record.status}")
        ]
      end
    end
  end
end
```

- [ ] **Step 5: テストを通す**

Run: `bundle exec rspec spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb`
Expected: PASS（2 出力行 + ヘッダ）

- [ ] **Step 6: lint + コミット**

```bash
bundle exec rubocop --force-exclusion app/services/monthly_summaries/csv/daily_detail_exporter.rb spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb
git add app/services/monthly_summaries/csv/daily_detail_exporter.rb spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb config/locales/ja.yml config/locales/en.yml
git commit -m "feat: DailyDetailExporter（日別明細 CSV・AR status i18n・NULL 空セル）"
```

---

### Task 4: routes + policy + controller（ストリーミング配線）+ request/policy spec

**Files:**
- Modify: `config/routes.rb`（`monthly_attendance_summaries` block）
- Modify: `app/policies/monthly_attendance_summary_policy.rb`
- Modify: `app/controllers/monthly_attendance_summaries_controller.rb`
- Test: `spec/requests/monthly_attendance_summaries_spec.rb`（追記）

**Interfaces:**
- Consumes: `SummaryExporter.call(summaries:)`（Task 2）・`DailyDetailExporter.call(records:, time_zone:)`（Task 3）・`AttendancePeriod`（既存）。
- Produces: `GET /monthly_attendance_summaries/summary_csv?year_month=YYYY-MM`・`GET /monthly_attendance_summaries/:id/detail_csv`。

- [ ] **Step 1: 失敗する request spec を書く**

`spec/requests/monthly_attendance_summaries_spec.rb` の最終 `end` 直前に追記:

```ruby
  describe "CSV エクスポート（3-3b）" do
    def host_headers = { "HOST" => tenant_host(org) }

    describe "summary_csv（collection・scope）" do
      it "manager は自分 + 部下のみ・他は除外（IDOR）" do
        manager = ActsAsTenant.with_tenant(org) { create(:user, :manager_role) }
        sub = ActsAsTenant.with_tenant(org) { create(:user, manager:, employee_code: "E777") }
        outsider = ActsAsTenant.with_tenant(org) { create(:user, employee_code: "E999") }
        ActsAsTenant.with_tenant(org) do
          create(:monthly_attendance_summary, user: sub, year_month: "2026-03")
          create(:monthly_attendance_summary, user: outsider, year_month: "2026-03")
        end
        sign_in manager
        get summary_csv_monthly_attendance_summaries_path, params: { year_month: "2026-03" }, headers: host_headers
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/csv")
        expect(response.body).to start_with("﻿")
        expect(response.body).to include("E777")
        expect(response.body).not_to include("E999")
      end

      it "hr_admin は全社員" do
        admin = ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) }
        ActsAsTenant.with_tenant(org) do
          create(:monthly_attendance_summary, user: create(:user, employee_code: "E001"), year_month: "2026-03")
          create(:monthly_attendance_summary, user: create(:user, employee_code: "E002"), year_month: "2026-03")
        end
        sign_in admin
        get summary_csv_monthly_attendance_summaries_path, params: { year_month: "2026-03" }, headers: host_headers
        expect(response.body).to include("E001").and include("E002")
      end

      it "不正 year_month は 400" do
        get summary_csv_monthly_attendance_summaries_path, params: { year_month: "2026-13" }, headers: host_headers
        expect(response).to have_http_status(:bad_request)
      end
    end

    describe "detail_csv（member）" do
      it "本人が自分の明細を DL（1 行=1 AR）" do
        period_day = Date.new(2026, 3, 5)
        summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user:, year_month: "2026-03") }
        ActsAsTenant.with_tenant(org) { create(:attendance_record, :done, user:, work_date: period_day) }
        get detail_csv_monthly_attendance_summary_path(summary), headers: host_headers
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/csv")
        expect(response.body).to include("2026-03-05")
      end

      it "scope 外 summary は 404（IDOR）" do
        other = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: create(:user), year_month: "2026-03") }
        get detail_csv_monthly_attendance_summary_path(other), headers: host_headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/requests/monthly_attendance_summaries_spec.rb -e "CSV エクスポート"`
Expected: FAIL（ルーティング `summary_csv_...` 未定義 → `NoMethodError`/`ActionController::RoutingError`）

- [ ] **Step 3: routes を追加**

`config/routes.rb` の `monthly_attendance_summaries` block を変更:

```ruby
  resources :monthly_attendance_summaries, only: %i[index show] do
    collection do
      patch :bulk_finalize
      get :summary_csv
    end
    member do
      patch :submit
      patch :finalize
      patch :defer
      get :detail_csv
    end
  end
```

- [ ] **Step 4: policy を追加**

`app/policies/monthly_attendance_summary_policy.rb` に述語を追加（`bulk_finalize?` の隣）:

```ruby
  def summary_csv? = index?
  def detail_csv? = show?
```

- [ ] **Step 5: controller を実装**

`app/controllers/monthly_attendance_summaries_controller.rb`:

`before_action` の `only:` に `:detail_csv` を追加:

```ruby
  before_action :set_summary, only: %i[show submit finalize defer detail_csv]
```

`bulk_finalize` の後（`private` の前）に 2 action を追加:

```ruby
  def summary_csv
    authorize MonthlyAttendanceSummary, :summary_csv?
    period = AttendancePeriod.new(organization: current_tenant, year_month: params[:year_month])
    summaries = policy_scope(MonthlyAttendanceSummary)
                  .where(year_month: period.label).includes(:user).order(:user_id).to_a
    stream_csv(MonthlySummaries::Csv::SummaryExporter.call(summaries:),
               "monthly_summary_#{period.label}.csv")
  rescue ArgumentError
    head :bad_request
  end

  def detail_csv
    authorize @summary, :detail_csv?
    period = AttendancePeriod.new(organization: current_tenant, year_month: @summary.year_month)
    records = AttendanceRecord.where(user_id: @summary.user_id, work_date: period.range).order(:work_date).to_a
    stream_csv(MonthlySummaries::Csv::DailyDetailExporter.call(records:, time_zone: current_tenant.time_zone),
               "daily_detail_#{@summary.user.employee_code}_#{period.label}.csv")
  end
```

`private` 以下に streaming ヘルパを追加:

```ruby
  # 行は呼び出し側で .to_a 事前確定済（テナント文脈下）ゆえ body は文字列整形のみ＝DB 非依存・テナント安全（D7）
  def stream_csv(enumerator, filename)
    response.headers["Content-Type"] = "text/csv; charset=utf-8"
    response.headers["Content-Disposition"] = %(attachment; filename="#{filename}")
    self.response_body = enumerator
  end
```

- [ ] **Step 6: テストを通す**

Run: `bundle exec rspec spec/requests/monthly_attendance_summaries_spec.rb`
Expected: PASS（既存 + CSV 新規）

- [ ] **Step 7: lint + brakeman + コミット**

```bash
bundle exec rubocop --force-exclusion app/controllers/monthly_attendance_summaries_controller.rb app/policies/monthly_attendance_summary_policy.rb config/routes.rb spec/requests/monthly_attendance_summaries_spec.rb
bin/brakeman --no-pager
git add app/controllers/monthly_attendance_summaries_controller.rb app/policies/monthly_attendance_summary_policy.rb config/routes.rb spec/requests/monthly_attendance_summaries_spec.rb
git commit -m "feat: CSV エクスポート action/routes/policy（policy_scope 起点・IDOR・streaming）"
```

---

### Task 5: UI 導線（index 年月セレクタ + サマリ DL / show 明細 DL）

**Files:**
- Modify: `app/views/monthly_attendance_summaries/index.html.erb`
- Modify: `app/views/monthly_attendance_summaries/show.html.erb`
- Test: `spec/requests/monthly_attendance_summaries_spec.rb`（追記）

**Interfaces:**
- Consumes: `summary_csv` / `detail_csv` ルート（Task 4）。

- [ ] **Step 1: 失敗する request spec を書く**

`spec/requests/monthly_attendance_summaries_spec.rb` の「CSV エクスポート」describe 内に追記:

```ruby
    describe "UI 導線" do
      def host_headers = { "HOST" => tenant_host(org) }

      it "index に月次サマリ CSV の DL リンクが出る" do
        get monthly_attendance_summaries_path, headers: host_headers
        expect(response.body).to include(summary_csv_monthly_attendance_summaries_path)
      end

      it "show に日別明細 CSV の DL リンクが出る" do
        summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user:, year_month: "2026-03") }
        get monthly_attendance_summary_path(summary), headers: host_headers
        expect(response.body).to include(detail_csv_monthly_attendance_summary_path(summary))
      end
    end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/requests/monthly_attendance_summaries_spec.rb -e "UI 導線"`
Expected: FAIL（リンク未描画）

- [ ] **Step 3: index に年月セレクタ + DL リンク**

`app/views/monthly_attendance_summaries/index.html.erb` の `<h1>月次締め</h1>` の直後に追記:

```erb
<section>
  <h2>月次サマリ CSV</h2>
  <%= form_with url: summary_csv_monthly_attendance_summaries_path, method: :get do |f| %>
    <%= f.label :year_month, "対象月（YYYY-MM）" %>
    <%= f.text_field :year_month, value: @summaries.first&.year_month, placeholder: "2026-03" %>
    <%= f.submit "サマリ CSV をダウンロード" %>
  <% end %>
</section>
```

- [ ] **Step 4: show に明細 DL リンク**

`app/views/monthly_attendance_summaries/show.html.erb` の `<dl>...</dl>` block の直後に追記:

```erb
<p><%= link_to "日別明細 CSV をダウンロード", detail_csv_monthly_attendance_summary_path(@summary) %></p>
```

- [ ] **Step 5: テストを通す**

Run: `bundle exec rspec spec/requests/monthly_attendance_summaries_spec.rb`
Expected: PASS

- [ ] **Step 6: lint + コミット**

```bash
bundle exec erb_lint app/views/monthly_attendance_summaries/index.html.erb app/views/monthly_attendance_summaries/show.html.erb || true
git add app/views/monthly_attendance_summaries/index.html.erb app/views/monthly_attendance_summaries/show.html.erb spec/requests/monthly_attendance_summaries_spec.rb
git commit -m "feat: CSV DL 導線（index 年月セレクタ + サマリ / show 明細）"
```

---

### Task 6: SPEC §6.4 穴埋め + 全体検証 + ROADMAP + PR

**Files:**
- Modify: `docs/SPEC.md`（§6.4 の月次サマリ CSV 列に社員コード・氏名を明記）
- Modify: `docs/ROADMAP.md`（3-3 行に 3-3b done・Phase 3 完了）

- [ ] **Step 1: SPEC §6.4 に社員識別子列を追記（D11 の穴埋め）**

`docs/SPEC.md` §6.4 の「月次サマリ CSV:」行頭に「**社員コード・氏名・**」を加える（給与システムが行を社員に突合できるよう列を明記）。該当箇所:

```
  - **月次サマリ CSV:** 社員コード・氏名・所定/実出勤日数・総労働/総残業・60h 超・法定休日・深夜・管理監督者フラグ・有給使用・遅刻早退・総休暇時間
```

- [ ] **Step 2: フル回帰 + lint + セキュリティ**

Run: `bundle exec rspec`
Expected: 全 PASS（既存 + 新規 CSV）

Run: `bundle exec rubocop --force-exclusion $(git diff --name-only main --diff-filter=d -- '*.rb') && bin/brakeman --no-pager`
Expected: no offenses / no warnings

- [ ] **Step 3: ROADMAP を Phase 3 完了に更新**

`docs/ROADMAP.md` の 3-3 行を 3-3b done・**`[x]`** へ更新（PR 番号は PR 作成後に確定追記）。例:

```markdown
- [x] **3-3 CSV 2 種**: 月次サマリ・日別明細（UTF-8 BOM・割増区分網羅・§6.4）。3-3a 休暇集計の素材整備（PR #16）＋ **3-3b CSV 出力**（`Csv::Row`/`SummaryExporter`/`DailyDetailExporter`・社員識別子列・formula-injection サニタイズ・NULL 空セル・policy_scope 起点 streaming・AR status i18n・SPEC §6.4 穴埋め）（PR #XX）。**Phase 3 完了**
```

- [ ] **Step 4: コミット**

```bash
git add docs/SPEC.md docs/ROADMAP.md
git commit -m "docs: SPEC §6.4 に社員識別子列を追記 + ROADMAP 3-3 完了"
```

- [ ] **Step 5: `/preflight` → レビュー → PR**

- `/preflight` で CI 等価検証。
- `tenant-isolation-reviewer`（CSV・policy_scope・streaming のテナント安全）を merge 前に起動。
- `gh pr create`（base main・`gh auth switch -u kei1110`）。本文に設計 spec リンク・3-3b スコープ・Phase 3 完了を明記。
- merge 後 `/spec-check` で §6.4 含む Phase 3 全域の SPEC↔実装乖離を確認（横断ルール）。

---

## Self-Review（spec カバレッジ）

- **§5.1 exporter（BOM/CRLF/RFC4180/サニタイズ/NULL/i18n/TZ）** → Task 1（Row）+ Task 2/3（exporter）✅
- **§5.1 formula-injection（D12・F1）** → Task 1 `Row.sanitize` + Task 2 氏名サニタイズ test ✅
- **§5.2 streaming（Enumerator-body・全行事前確定・テナント安全）** → Task 4 `stream_csv` + `.to_a` ✅
- **§4 列マッピング（社員コード/氏名 D11・管理監督者 1/0・休暇 2 列）** → Task 2 ✅／明細 NULL 空セル → Task 3 ✅
- **§6.1 routes** → Task 4 ✅
- **§6.2 controller（summary_csv collection・policy_scope・year_month 400・detail_csv member・set_summary・生 where 注記）** → Task 4 ✅
- **§6.3 policy（summary_csv?=index? / detail_csv?=show?）** → Task 4 ✅
- **§6.4 UI（index 年月セレクタ + DL・show DL）** → Task 5 ✅
- **AR status i18n（未整備の補充）** → Task 3 ✅
- **SPEC §6.4 穴埋め（社員識別子列）** → Task 6 ✅
- **多視点レビュー反映**: F1 サニタイズ（Task 1/2）・F2 識別子列（Task 2/6）・streaming テナント安全（Task 4・事前 .to_a）・NULL 空セル（Task 3）。残（partial index 不要・LeaveAggregator cross-ref コメント等の 3-3a Minor）は本スライス対象外。
- **範囲外**: 通知（4-1）・リッチ ViewComponent（Phase 5）・CSV 非同期化（§16.2・YAGNI）。

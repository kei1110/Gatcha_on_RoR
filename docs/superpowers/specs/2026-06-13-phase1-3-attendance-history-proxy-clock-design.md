# Phase 1-3 設計 — AttendanceHistory（追記専用監査証跡）+ 代理打刻

> 対象: docs/ROADMAP.md 1-3 ／ SPEC §4.14（追記専用 3 段不変防御）・§6.1（代理打刻）・§3.4–3.5（認可・オーナー/操作者分離）・§7.6（撤回時の履歴参照復元）
> 体制: 折衷案 v2（設計/計画/SPEC 準拠 = 主・実装 = サブ・品質 = 独立サブ）。models / jobs / migration に触れるため `tenant-isolation-reviewer` を merge 前に通す
> ユーザー決定（2026-06-13）: 履歴の書込は **proxy_clock のみ**（自己打刻は記録しない）／ DB 不変防御 = **Postgres トリガー**を **fx gem** で schema.rb 捕捉／ **`actor_id` 構造化列**を追加（§4.14 へ逆反映）／ 代理打刻権限は **manager(直接部下) + hr_admin(全員)**／ 本人通知 = **最小バナーを前倒し**（push 本体は 4-1）
> 多視点レビュー反映（2026-06-13・7 視点）: **§R に集約**。High 6 件（polymorphic source 検証 R-1・テナント二層 R-2・トリガー脅威モデル R-3・ProxyClockOut 骨格再利用 R-4・AR バイパス test R-5・本人バナー前倒し R-6）+ Med/Low。**IDOR 罠記述の事実誤認を訂正**（top-level UserPolicy 不在ゆえ NotDefinedError で fail-closed）。各節は §R で上書き解釈

## §0 方針・前提（SPEC 確定事項の再掲 + 宣言）

- **オーナーと操作者の分離（§3.5）**: `user_id` = 対象社員（当事者アクセスの軸・Pundit）、`actor_id` = 操作者（代理打刻した管理者・109 条/適正把握の軸）。両者を一列に潰さない。SPEC §3.5「代理打刻でも user_id は対象社員、操作者は AttendanceHistory 側に別途記録」を構造化列で実装する。
- **書き込み側は代理打刻から始まる（ROADMAP 横断ルール）**: モデルと 3 段不変防御は 1-3 で前倒し全実装（Phase 2 承認副作用が依存）。本スライスの **唯一の writer は `proxy_clock`**。残り 8 event_type（`clock_in`/`clock_out`/`leave_approved`/`leave_withdrawn`/`clock_change_approved`/`absence_confirmed`/`absence_to_paid`/`interval_shortage`）は**整数を予約しコメント温存**、消費スライス（2-2/2-3/2-4/2-5/4-2/4-4）が追記。
- **自己打刻(clock_in/out)は履歴を残さない（YAGNI 決定）**: 通常打刻の真正性は `AttendanceRecord` 自体 + `created_at` が一次記録。監査表の価値は *変更*・*代理*・*承認* イベントにあり、自己打刻を二重記録しない。`event_type` に 0/1 を予約はするが、本スライスでは書かない。
- **時刻不変条件の維持（1-1 §0）**: 代理打刻は `Time.current`（now-on-behalf）のみ。**任意時刻の打刻・上書き経路は作らない** — 過去時刻の補正は 2-3 打刻変更申請に一本化（「証跡なき改変経路ゼロ」を 109 条・適正把握の趣旨に対する設計不変条件として維持）。
- **通知は Phase 4 へ後送り**: §6.1 の「対象社員へ即時通知」は通知基盤（4-1）接続後。本スライスは **note 自動追記 + 履歴記録まで**。サービスに「ここに通知を差す」継ぎ目コメントのみ残す。
- **消費分のみスキーマ原則（0b-5 以来）**: `attendance_records` には今回消費する `proxy_clock_reason` / `note` のみ追加。`is_holiday_work`・`absence_reason`・`archived` は各消費スライスで追加。
- **法定値・コンプラ非該当**: 本スライスは §8 コンプラ判定に触れない（labor-law レビューは不要、tenant 分離レビューを優先）。

## §1 データモデル — `attendance_histories`（新テーブル・追記専用）

§4.14 のカラム群 + `actor_id`。**`created_at` のみ持ち `updated_at` は置かない**（追記専用ゆえ常に同値で無意味＝不変性の意思表示。Rails は `updated_at` 列不在を許容）。

| 区分 | カラム | 型 | 制約 |
|------|--------|-----|------|
| テナント | `organization_id` | bigint | NOT NULL・FK organizations |
| 対象 | `user_id` | bigint | NOT NULL・複合 FK `(organization_id, user_id)→users(organization_id, id)` |
| 操作者 | `actor_id` | bigint | **NULL 許容**（Phase 4 のシステム起因イベントは actor 不在）・複合 FK `(organization_id, actor_id)→users(organization_id, id)`（MATCH SIMPLE: actor_id NULL 時は非検査） |
| イベント | `event_date` | date | NOT NULL |
| | `event_type` | integer (enum) | NOT NULL |
| | `source_type` / `source_id` | string / bigint | NULL（polymorphic 起因レコード） |
| 前後値 | `previous_status` / `new_status` | integer | NULL（生 integer・後述） |
| | `previous_clock_in` / `new_clock_in` | timestamptz | NULL |
| | `previous_clock_out` / `new_clock_out` | timestamptz | NULL |
| | `previous_is_late` / `new_is_late` | boolean | NULL |
| | `previous_late_minutes` / `new_late_minutes` | integer | NULL |
| | `previous_is_early_leave` / `new_is_early_leave` | boolean | NULL |
| | `previous_early_leave_minutes` / `new_early_leave_minutes` | integer | NULL |
| 備考 | `note` | text | NULL |
| | `created_at` | timestamptz | NOT NULL（`updated_at` なし） |

**`event_type` enum（§4.14 順序固定・整数マッピング固定 spec 必須）:**
```ruby
enum :event_type, {
  clock_in: 0, clock_out: 1, leave_approved: 2, leave_withdrawn: 3,
  clock_change_approved: 4, absence_confirmed: 5, absence_to_paid: 6,
  proxy_clock: 7, interval_shortage: 8
}, validate: true
# 本スライスで書くのは proxy_clock(7) のみ。他は予約（消費スライスのコメント参照）
```

**`previous/new_status` は生 integer 保持**: `AttendanceRecord.statuses` と同じ整数だが、AR 側 enum は現状 2 値（working/clocked_out）のみ宣言ゆえ、ここで enum を二重宣言すると 2-2 で AR 側に値が増えたとき drift する。コメントで「= AttendanceRecord.statuses の整数」と対応を明記し、enum 宣言はしない。

**index:**
- `[organization_id]` — acts_as_tenant
- `[organization_id, user_id, event_date]` — 「社員×勤務日の履歴」参照（§7.6 撤回時の状態復元・Phase 2 が消費）
- `[source_type, source_id]` — polymorphic 逆引き（撤回が起因レコードから履歴を辿る）
- **`[organization_id, id]` unique は置かない** — 葉テーブル・追記専用で被参照予定ゼロ。最大級に伸びる監査表に未使用 unique index を足さない（書込コスト回避）。0b-4 の「将来の複合 FK 受け皿として規約で置く」とは判断を分ける（**本テーブルを FK 参照する設計が現れたらそのスライスで追加**）。

**モデル `AttendanceHistory`:**
```ruby
class AttendanceHistory < ApplicationRecord
  acts_as_tenant(:organization)
  belongs_to :user
  belongs_to :actor, class_name: "User", optional: true       # 操作者（§3.5 分離）
  belongs_to :source, polymorphic: true, optional: true

  enum :event_type, { ... }, validate: true

  validates :event_date, presence: true
  # previous/new 値は event_type 依存で可変ゆえ presence は課さない

  # ── 不変防御 §2 段①② ──
  def readonly? = persisted?                                   # 永続後の UPDATE を AR 層で封鎖
  before_update  { raise ActiveRecord::ReadOnlyRecord }        # readonly? が止めぬ経路の belt
  before_destroy { raise ActiveRecord::ReadOnlyRecord }        # readonly? は destroy を止めない
end
```

## §2 不変防御の実装（3 段・fx gem）

§4.14 の (1)(2)(3) を実装する。**REVOKE を採らない理由**: dev/test/CI が superuser 接続のため REVOKE はバイパスされ、層③をテストで守れない（トリガーは superuser にも発火する）。

1. **`readonly? = persisted?`**（§1 モデル）— 通常の AR `save`/`update` で `ActiveRecord::ReadOnlyRecord`。
2. **`before_update`/`before_destroy` → `raise ActiveRecord::ReadOnlyRecord`**（§1 モデル）— `destroy` は `readonly?` で止まらないため必須。
3. **DB トリガー（fx で schema.rb にダンプ）** — `update_all`/`delete_all`/raw SQL/`TRUNCATE` を捕捉（5 年法的証跡の最終防衛）:
   - `gem "fx"` を Gemfile に追加（`~>` で悲観固定）。fx は SchemaDumper をフックし `create_function`/`create_trigger` を schema.rb に出力 → `maintain_test_schema!`（rails_helper）と CI の `db:test:prepare` が schema.rb をロードしてテスト DB に**トリガーを再現**する。
   - `db/functions/attendance_histories_immutable_v01.sql`:
     ```sql
     CREATE OR REPLACE FUNCTION attendance_histories_immutable() RETURNS trigger AS $$
     BEGIN
       RAISE EXCEPTION 'attendance_histories is append-only; % is blocked (SPEC §4.14, 5-year legal trail)', TG_OP
         USING ERRCODE = 'restrict_violation';   -- OLD を参照しない → UPDATE/DELETE/TRUNCATE で共用可
     END;
     $$ LANGUAGE plpgsql;
     ```
   - `db/triggers/attendance_histories_no_mutate_v01.sql`:
     ```sql
     CREATE TRIGGER attendance_histories_no_mutate
       BEFORE UPDATE OR DELETE ON attendance_histories
       FOR EACH ROW EXECUTE FUNCTION attendance_histories_immutable();
     ```
   - `db/triggers/attendance_histories_no_truncate_v01.sql`:
     ```sql
     CREATE TRIGGER attendance_histories_no_truncate
       BEFORE TRUNCATE ON attendance_histories
       FOR EACH STATEMENT EXECUTE FUNCTION attendance_histories_immutable();  -- 行トリガーがすり抜ける TRUNCATE を塞ぐ
     ```
   - migration: `create_table` → `create_function`（fx）→ `create_trigger` ×2（fx）。

> **要検証（§8 gotcha 候補）**: fx の SchemaDumper フックと既存 `config/initializers/rails_exclusion_constraint_where_fix.rb`（こちらも dumper を prepend）の**共存**。両者 prepend で順序非依存に動くはずだが、`db:schema:dump` → `db:schema:load` のラウンドトリップ（exclusion constraint + trigger 両方を含む）を実際に回して確認し、結果を RAILS_GOTCHAS へ記録する。

## §3 `attendance_records` 追加カラム + 打刻共有部品の抽出

**migration（消費分のみ）:**
- `proxy_clock_reason` integer NULL — enum `system_failure:0, unreachable:1, forgot_punch:2, other:3`（§6.1）
- `note` text NULL（代理打刻・インターバル不足の自動追記先・§4.8）

**`AttendanceRecord` 追加:**
```ruby
enum :proxy_clock_reason, { system_failure: 0, unreachable: 1, forgot_punch: 2, other: 3 },
     validate: true   # nil 許容（大半のレコードは代理打刻でない）。permit する enum ゆえ毒入力対策（RAILS_GOTCHAS: enum validate）
```

**共有部品の抽出**（自己打刻と代理打刻で述語/手順を割らない・1-1 §2 の「述語の単一ソース」を踏襲）:
- `Clockings.snapshot_pattern_id(user, date)` = `user.user_work_patterns.effective_on(date).pick(:work_pattern_id)` ← `ClockIn` と `ProxyClockIn` が共有（§4.8 スナップショット単一ソース。複合 FK が最終防衛、effective_on がテナント内二重保証ゆえ追加検証不要）。
- `Clockings.append_note(existing, fragment)` = `existing.present? ? "#{existing}；#{fragment}" : fragment` ← `；` 連結の単一実装。
- 既存 `ClockIn` をリファクタしてこの共有メソッドを使う（挙動不変・回帰 spec で担保）。

## §4 代理打刻サービス（`Clockings::ProxyClockIn` / `ProxyClockOut`）

自己打刻サービスとは**別クラス**（current_user 固定の不変条件を壊さない）。署名 `call(operator:, target_user:, reason:)`。戻り値は既存 `Clockings::Result`。

**共通規約:**
- 本体を `ActsAsTenant.with_tenant(operator.organization)` で自己完結。
- **fail-closed テナント検証**（console 直叩き耐性・model コメントの宿題回収）:
  `return failure(:cross_tenant) unless target_user.organization_id == operator.organization_id`
- 全クエリは `target_user.attendance_records` 起点。window / `working_within` / 同日存在ガードは §1-1 と同一述語を再利用。
- note フラグメント: `"代理打刻（#{出勤|退勤}）：#{operator.name} が #{org TZ の Time.current} に実施（理由: #{I18n proxy_clock_reason}）"`。`Clockings.append_note` で AttendanceRecord.note に連結し、AttendanceHistory.note にも同フラグメントを格納。
- **継ぎ目コメント**: 「Phase 4-1 でここに対象社員通知を差す」。

**`Clockings::ProxyClockIn.call(operator:, target_user:, reason:)`**
```
with_tenant(operator.organization):
  cross_tenant ガード
  today = operator.organization.today
  ガード: target_user.attendance_records.exists?(work_date: today) → failure(:already_clocked_in)
         target_user.attendance_records.working_within(window(today)).exists? → failure(:still_working)
  fragment = note フラグメント（出勤）
  transaction:                                   # 打刻 + 履歴を原子的に（履歴は法的必須）
    record = target_user.attendance_records.create!(
      work_date: today, clock_in: Time.current.change(usec: 0),
      work_pattern_id: Clockings.snapshot_pattern_id(target_user, today),
      status: :working, proxy_clock_reason: reason, note: fragment)
    record_history(record, operator:, fragment:, previous: nil)   # previous_* 全 nil・new_* = 作成値
  Result.success(record)
rescue RecordNotUnique → failure(:already_clocked_in)            # tx 外 rescue（同時タブ/二重タップ）
rescue RecordInvalid/StatementInvalid → report + failure(:proxy_clock_failed)
```

**`Clockings::ProxyClockOut.call(operator:, target_user:, reason:)`**
```
with_tenant(operator.organization):
  cross_tenant ガード
  record = target_user.attendance_records.working_within(window(today)).order(work_date: :desc).first
  failure(:not_working) if nil
  result =
    begin
      record.with_lock do                          # 行ロック + 暗黙 tx
        next failure(:not_working) unless record.working?   # ロック待ちの間に他方が退勤済み
        previous = snapshot_of(record)              # clock_out=nil, status=working …
        record.update!(clock_out: Time.current.change(usec: 0), status: :clocked_out,
                       proxy_clock_reason: reason, note: Clockings.append_note(record.note, fragment))
        record_history(record, operator:, fragment:, previous:)   # 履歴も同一 tx（必須・原子的）
        Result.success(record)
      end
    rescue RecordInvalid, StatementInvalid => e     # ★ rescue は with_lock の外（RAILS_GOTCHAS）
      Rails.error.report(e, ...); failure(:proxy_clock_failed)    #   tx 内 rescue は偽 success + 更新消失
    end
  Clockings::Recalculate.call(record:) rescue report   # ★ commit 後（lock 外）= 再計算失敗は 8 列 NULL に閉じる
  result
```

**`record_history`（private 共有ヘルパ）**: `AttendanceHistory.create!(organization:, user: target_user, actor: operator, event_date: record.work_date, event_type: :proxy_clock, source: record, note: fragment, **前後値)`。`source` = 被作用 `AttendanceRecord`（proxy_clock は起因 request を持たないため被作用レコードを指す。承認系の source = LeaveRequest 等とは意味が違うことをコメント明記）。

> **トランザクション境界（1-2 との差分）**: 1-2 ClockOut は「退勤確定（必須）」と「再計算（失敗許容）」を別 tx に割った。1-3 は **履歴書込も法的必須**ゆえ `update!`/`create!` と history を**同一 tx に同居**させ、再計算のみ外へ出す。履歴 INSERT が失敗したら退勤ごとロールバックさせる（証跡なき改変を作らない）。rescue は**必ず with_lock の外**（RAILS_GOTCHAS「tx 内で SQL 例外 rescue → 偽 success + 更新消失」回避）。
> **proxy_clock 履歴の計算列の限界**: 再計算は tx 外ゆえ、clock-out 履歴の `new_is_late`/`new_deep_night` 等は**再計算前の値**（多くは nil）。proxy_clock イベントの本質（誰が・いつ・どの時刻に・status 遷移）は捕捉される。計算列の前後値が真に効くのは 2-3 `clock_change_approved`（時刻変更が遅刻フラグを反転させる）。AttendanceRecord が計算値の正本、履歴の計算列は補助という責務をコメント明記。

## §5 認可・コントローラ・UI

**Policy `ProxyClockingPolicy`（headless + Scope）:**
```ruby
class ProxyClockingPolicy < ApplicationPolicy
  def index?     = manager_or_admin?
  def clock_in?  = manager_or_admin?
  def clock_out? = manager_or_admin?

  class Scope < ApplicationPolicy::Scope
    # ロスター = 代理打刻の対象集合。在籍者・自分除外（自分は通常打刻）。
    # organization_id 明示（without_tenant 文脈耐性・Admin::UserPolicy::Scope と同型）
    def resolve
      base =
        if user.hr_admin?
          scope.where(organization_id: user.organization_id)            # 全員
        elsif user.manager?
          scope.where(organization_id: user.organization_id, manager_id: user.id)  # 直接部下
        else
          scope.none                                                    # fail-closed
        end
      base.where(active: true).where.not(id: user.id)
    end
  end

  private
  def manager_or_admin? = user.manager? || user.hr_admin?
end
```

**ルート**（Admin 名前空間ではない＝マスタは hr_admin、代理打刻は manager 機能。トップレベル）:
```ruby
resources :proxy_clockings, only: %i[index] do
  member { post :clock_in; post :clock_out }   # :id = 対象社員 id
end
```

**コントローラ `ProxyClockingsController`:**
- **scope 解決の罠（多視点レビューで訂正）**: `policy_scope(User)` 単独は `User` のクラスから Scope を解決するが、本リポジトリに **top-level `UserPolicy` は不在**（`app/policies/` は `admin/` のみ）ゆえ実際は `Pundit::NotDefinedError` で **fail-closed**（当初記述の「`UserPolicy::Scope` に越権解決」は誤り）。それでも `policy_scope(User, policy_scope_class: ProxyClockingPolicy::Scope)` の**明示が必須**: ①明示しないと NotDefinedError で動かない ②将来 top-level `UserPolicy` を足すと黙って `UserPolicy::Scope`（manager を部下に絞らない）へ解決され**越権化する**——明示は現状の正しさと将来の越権予防を兼ねる。Pundit 2.5.2 が kwarg を正式サポート（`Pundit::Authorization#policy_scope`・`verify_policy_scoped` フラグも立つ）。ヘルパを 1 メソッドに閉じる:
  ```ruby
  def roster = policy_scope(User, policy_scope_class: ProxyClockingPolicy::Scope)
  ```
- `index`: `@subordinates = roster`。各社員の打刻状態は `Clockings::State` 流用 or 軽量述語で算出。`authorize :proxy_clocking, :index?`（headless symbol → `ProxyClockingPolicy.new(user, :proxy_clocking).index?`・既存 `ClockingPolicy` と同型）。
- `clock_in`/`clock_out`: `target = roster.find(params[:id])`（**scope 外は 404・IDOR 対策**）→ `authorize :proxy_clocking, :clock_in?` → reason を permit（enum 値の presence 検証）→ `Clockings::ProxyClockIn.call(operator: current_user, target_user: target, reason:)` → `redirect_to proxy_clockings_path, status: :see_other`（成功 notice / 失敗 alert）。
- 認可の二層: ① role ゲート（policy `manager_or_admin?`）② 対象ゲート（`roster.find` の 404）。policy `clock_in?` は record 非依存ゆえ「対象が部下か」は scope.find に委譲（SPEC §3.4「params 対象指定は scope に対する find で解決し scope 外は 404」）。
- 書込系 redirect は一律 `status: :see_other`（Turbo 302 メソッド保持・RAILS_GOTCHAS）。

**UI（最小・既存マスタ画面同等のトーン）:**
- 部下ロスター（ViewComponent）: 各行 = 社員名 + 現在の打刻状態バッジ + `proxy_clock_reason` の `<select>` + `代理出勤`/`代理退勤`（`button_to` method: post・`form` に reason を内包）。
- manager/hr_admin に「代理打刻」入口（ナビ）。employee には非表示（policy ゲート）。
- i18n: `proxy_clock_reason` の日本語ラベル・成功/失敗メッセージ・ロスター見出しを `ja.yml` に追加（default locale ja は 0b-2 で確立）。

## §6 テスト戦略（`/gen-spec` 規約・tenant 文脈ラップ必須）

- **model（attendance_history_spec）**: ① `readonly?` が persisted で true ② `update!`/`destroy` が `ReadOnlyRecord` ③ **raw SQL `UPDATE`/`DELETE`/`TRUNCATE` が `ActiveRecord::StatementInvalid`（PG restrict_violation・トリガー実発火）**④ `event_type` 整数固定（7=proxy_clock 等）⑤ 複合 FK 越境拒否（actor/user 他テナント）⑥ `actor_id` NULL 許容 ⑦ `updated_at` 列不在でも create 可。
- **service（proxy_clock_in/out_spec）**: 正常系（record 作成/更新 + history 1 件 + actor/前後値/note）・ガード（already_clocked_in / still_working / not_working）・`cross_tenant` fail-closed・note `；`連結・**history 失敗時に退勤ごとロールバック**（nonexistent 制約注入 or stub で StatementInvalid）・recalc は commit 後・`snapshot_pattern_id` 共有の回帰。
- **policy（proxy_clocking_policy_spec）**: manager×直接部下=許可 / hr_admin×全員=許可 / employee=拒否 / manager×非部下=Scope 外 / 自分・inactive=roster 除外。
- **request/system**: scope 外 `find` → 404・reason 未選択 → 422・see_other・ロスター表示・代理打刻後に対象社員の AttendanceRecord/note が更新。
- tenant 未設定文脈（request/system）でのモデル操作は `ActsAsTenant.with_tenant(org){...}` でラップ（RAILS_GOTCHAS）。

## §7 スコープ外（明示・YAGNI）

- 自己打刻(clock_in/out)の履歴記録（event_type 0/1 は予約のみ）。
- 対象社員への通知（§6.1 後段）→ Phase 4-1。
- 任意時刻の代理打刻・過去日への代理 new_entry → 2-3 打刻変更申請。
- 階層を辿る部下（`subordinate_of?`）→ 直接部下のみ（必要時に再判断）。
- 履歴の計算列を再計算後の確定値にする最適化（限界は §4 注記で許容）。
- AttendanceHistory を FK 参照する設計（→ そのとき `[organization_id, id]` unique を追加）。

## §8 docs 逆反映 + 新規 gotcha 候補

- **SPEC §4.14**: `actor_id` 列を追記（オーナー/操作者分離の構造化）。本 PR で amend。
- **SPEC §3（line 211）**: 「代理打刻 = manager? かつ部下」→ **manager(直接部下) + hr_admin(組織全員)** に拡張記述。本 PR で amend。
- **ROADMAP 1-3 行**: チェック + PR 番号。
- **RAILS_GOTCHAS（要検証で追記）**: ① fx SchemaDumper フック × exclusion-constraint パッチの共存（ラウンドトリップ実測・§R-2 でハードゲート化）② 追記専用テーブルのトリガー不変防御を schema.rb 経由でテストする型（fx 採用の根拠）③ **`policy_scope(Model)` は Model クラスから Scope を解決。対象 Model に top-level Policy が無ければ `NotDefinedError`（fail-closed）、有れば**そのポリシー**の Scope に解決される。別ポリシーの Scope を当てる headless policy は `policy_scope(Model, policy_scope_class:)` を明示（明示せぬと現状 NotDefined・将来 top-level Policy 追加で越権化）④ 監査テーブルの拒否 spec は transactional fixtures 下で example tx を道連れ abort → `transaction(requires_new:)` で savepoint 隔離（§R-5）。
- **gen-spec 規約**: 監査テーブルの「raw SQL 拒否」の書き方を雛形へ反映するか検討。

## §R 多視点レビュー反映（2026-06-13・7 視点）

7 視点の独立 critique を統合し、採用した変更を本節に集約する（body 各節はこの addendum で上書き解釈）。労務照合は鮮度警告つき（BUNDLED_INDEX_AGED・生成 2026-04-02・労基法 109 条のみ照合済 <https://laws.e-gov.go.jp/law/322AC0000000049>。適正把握ガイドライン 基発 0120 第 3 号は MCP 対象外で未照合）。

### R-1【High・tenant】polymorphic `source` の同一テナント検証（構造防衛ゼロの穴）
polymorphic は複合 FK を張れず、§3.6(2) の二層（モデル検証＋複合 FK）が source に対し**ゼロ層**になる。Phase 2 consumer（2-2/2-3）が request 由来で `source = LeaveRequest` を代入する経路に検証が無いと cross-tenant source_id を書ける。
→ モデルに `validate :source_must_belong_to_same_organization`（`source&.organization_id == organization_id`・`user.rb` の `manager_must_belong_to_same_organization` 同型）。spec で他テナント source 拒否。**読み取り越境自体は acts_as_tenant default_scope が nil 解決で塞ぐが、不可逆な追記表ゆえ書込時の構造防衛を merge 前に入れる**。

### R-2【High・tenant/audit】`user`/`actor` もモデル層の同一テナント検証（§3.6 二層の徹底）
複合 FK が DB 層で弾く点は良いが、§3.6(2) はモデル検証**も**要求（`user.rb` 先例も両持ち）。`raise InvalidForeignKey` 丸投げでなくクリーンな検証エラーで surface。
→ `user`/`actor` に同一組織 validation 追加（DB FK は最終防衛として残す）。`actor_id` は MATCH SIMPLE 既定（NULL 時非検査）を migration コメント＋spec で固定し、**MATCH FULL にしない**（org 非 NULL/actor NULL の正当な Phase4 行を壊すため）。

### R-3【High・audit】トリガー不変性の脅威モデルを正直に明記（owner/superuser バイパス）
トリガーは DML を全ロールで止めるが、table **owner** は `ALTER TABLE ... DISABLE TRIGGER`、**superuser** は `SET session_replication_role = replica` でバイパス可。本番 `database.yml` は単一ロール `gatcha` で migration を流す＝**app ロール＝owner** になりがちで、SQLi/rogue `execute` が owner 権限で改竄成立し得る。
→ ① §0/§2 に脅威モデル明記:「トリガーは*プログラム的・偶発的*改竄（`update_all`/raw SQL/`TRUNCATE`）を防ぐ。owner/superuser の*能動的*改竄は防がない——本番は **table owner ≠ app 接続ロール**（migration を別ロールで流す or `ALTER TABLE ... OWNER TO`、最低限 app ロールから trigger 無効化能力を外す）を Phase 5-3 運用整備の完了条件とする」。② v1 は単一ロールゆえ「honest-mistake 防御」と位置づけを明記し過信を防ぐ。

### R-4【High・pragma】ProxyClockOut は ClockOut 骨格を分岐コピーしない
`with_lock + commit 後 recalc` は今日（2026-06-13）仕留めた tx 境界 GOTCHA の対策そのもの。分岐コピー 2 本は片方だけ直す回帰温床。pseudocode の `Recalculate.call rescue report`（裸 rescue）は ClockOut の型付き private `recalculate`（`attendance_record_id` context 付き Sentry report）より退化。
→ ① recalc は既存 `Clockings::ClockOut#recalculate` 相当を共有（`Clockings.recalculate_safely(record)` module メソッド抽出）。② with_lock 骨格は ProxyClockOut にも「ClockOut と同期・GOTCHAS tx-boundary 参照」コメント必須。③ **「rescue は with_lock の外」を ClockOut/ProxyClockOut 双方で assert する spec を必須**（nonexistent 制約注入で偽 success 不在を実証）。

### R-5【High・audit】3 段防御の層②は実質 destroy 専用 — AR バイパス経路をテストで実証
層① `readonly?` ② `before_*` は `update_all`/`delete_all`/`update_columns`/`record.delete`/`upsert_all(on_duplicate:)` を**一切止めない**——トリガー③のみが捕捉。
→ ① model spec に上記 AR バイパス各経路が `StatementInvalid`（restrict_violation 実発火）で拒否される example を追加（「①②が止める経路」と「③だけが止める経路」を仕分けコメント）。② **拒否 DML は `ActiveRecord::Base.transaction(requires_new: true)`（savepoint）で包む**——`RAISE EXCEPTION` が example tx を aborted にし後続クエリが `PG::InFailedSqlTransaction` で偽 FAIL するため（transactional fixtures・RAILS_GOTCHAS 同根）。gen-spec 雛形へ「監査拒否 example は requires_new」を反映。③ モデル/SQL に役割コメント:「真の backstop は trigger・AR callback は fast-fail／②本体は destroy（readonly? は destroy を止めない）／INSERT は append のため**意図的に非対象**（後続スライスが `OR INSERT` を足すと全 writer 死）」。

### R-6【High・labor／ユーザー決定】本人通知 = 最小バナーを前倒し
SPEC §6.1 は代理打刻時の本人即時通知を必須列挙。後送りは本人が知らぬ間の改変窓を作る（労基法 109 条・適正把握）。**ユーザー決定: 最小バナーを本スライスに前倒し**。
→ 本人の §12.1 ホーム/勤怠ビュー（1-1 構築済）に、当該日の `AttendanceRecord.proxy_clock_reason.present?` を述語に「この打刻は {操作者名} による代理打刻です（理由: X）。時刻が異なる場合は打刻変更申請を提出してください」インジケータを表示。操作者名は AttendanceHistory(proxy_clock).actor から解決（note prose に依存しない）。**push 通知本体は 4-1 のまま**——バナーは既存データを読む状態表示で「通知送信」ではなく、ROADMAP line100「通知を 1 箇所に集める」意図を壊さない。打刻変更申請（2-3 未実装）への能動リンクは案内テキストのみ（導線本体は 2-3）。社労士確認 #17 を NOTES へ追記（通知後送りの適否・`forgot_punch` の now 記録・`other` の証跡十分性）。

### R-7【Med・security】reason 必須を機構で強制
`proxy_clock_reason` は nullable + `enum validate:true`（nil 許容）ゆえ、reason を**省いた**POST は NULL reason の代理打刻を生成し §6.1「理由必須」を骨抜き。
→ service で `failure(:reason_required) if reason.blank?`（enum 毒入力 `""` は 422、欠落 nil はここで塞ぐ二段）。controller の permit と合わせ二重。

### R-8【Med・security】service 層の認可非対称を是正
`cross_tenant` だけ service で fail-closed なのに、subordinate 境界と self 除外は controller roster scope のみ。console/Phase2 caller 直叩きで越権・自己代理素通り。
→ ① service に `operator == target` 拒否（`failure(:self_proxy_forbidden)`・自己代理は通常打刻へ）。② subordinate 境界は「controller scope 専任・service は認可境界ではない」をコメント明記し Phase2 caller へ申し送り（service で部下判定を二重実装はしない＝Pundit 一元化を守る）。

### R-9【Med・labor】actor_id 必須を event_type 別に強制（不変ゆえ誤り永久化）
actor_id は Phase4 システムイベント用に NULL 許容だが、proxy_clock（＋承認系）は適正把握上 actor 必須。誤経路で actor 欠落の proxy_clock を INSERT すると「誰が」鎖が切れ、不変トリガーで事後修正不能。
→ `validates :actor_id, presence: true, if: -> { proxy_clock? }`（将来の actor 必須 event_type 群を集合で持つ）。多層なら部分 CHECK `event_type IN (actor必須群) ⇒ actor_id NOT NULL` も検討（不変＝事前防御の価値が高い）。

### R-10【Med・pragma】hr_admin ロスターの N+1／件数上限
hr_admin ロスター＝組織全員 × per-row `Clockings::State` 算出は N+1・上限なしで性能崖。
→ 打刻状態をバッチ 1 クエリで先読み（当日 working を `where(user_id: roster_ids)` で一括取得しメモリ突合）or ページング。最低でも §7 に「組織規模次第で再訪」を明記。manager(直接部下) は許容、hr_admin が問題。

### R-11【Med・labor】§11.2 合法的匿名化/削除 vs 不変トリガー
③ `BEFORE UPDATE OR DELETE/TRUNCATE` は 5 年超データの匿名化（UPDATE）・削除（DELETE）も恒久ブロック。v1 は削除ジョブ無し（YAGNI）で即時不整合は無いが、Phase 11 archival/匿名化でトリガーが壁。
→ §8 docs 逆反映 or RAILS_GOTCHAS に「不変関数は §11.2 匿名化/削除のため**制御付きバイパス**（`_v01` 版関数差替 or 専用 role/GUC）が将来必須」明記。`_v01.sql` 版管理が差替パスを既に確保している点を設計意図として残す（個情法本文は未照合）。

### R-12【Med・audit/labor】proxy_clock 履歴の計算列 staleness を契約化
再計算が tx 外ゆえ proxy_clock_out 履歴の `new_is_late` 等は再計算前値（NULL）で恒久確定。NULL（未計算）と false（計算済・遅刻なし）が boolean nullable で区別不能 → 監査閲覧者の誤読、§7.6 復元汚染。
→ ① **§7.6 撤回復元は proxy_clock 行の計算列を source にしない**契約を §4.14/§7.6 へ逆反映。② 監査 UI/CSV（§6.4/§11.1）は計算値を**常に AttendanceRecord から解決**し履歴計算列を賃金証跡に使わない。③ proxy 時刻自体が不正確（forgot_punch）ゆえ NULL の方が安全という両面を列コメントに残す。

### R-13【Low・採用】小粒の改善（spec 反映）
- **index**: `[source_type, source_id]` → **`[organization_id, source_type, source_id]`**（org 前置規約）。操作者起点監査（内部統制・労基署の特定管理者調査・§5-1 是正チェックリスト §8.2）のため **`[organization_id, actor_id]` を追加**（actor 全表スキャン回避）。
- **二軸の明記**: `event_date`=対象勤務日／`created_at`=操作時刻（夜勤跨ぎで乖離）を §4.14 に固定。
- **`previous/new_status` 整数凍結**: 「AR status の整数マッピングは append-only/凍結」を §4.14 に併記（リオーダで履歴誤デコードを防ぐ）。書込時は `AttendanceRecord.statuses[...]` で整数化（文字列誤投入防止）。
- **window(today) 限定の周知**: proxy_clock_out は当日 working のみ対象。前日以前の退勤漏れ救済は 2-3 打刻変更申請（§6.8 導線にその旨明記・now 固定不変条件との整合）。
- **inactive 対象の開き record**: roster は `active:true` のみゆえ、勤務中に無効化された社員の開いた working レコードを代理退勤で閉じられない。回復導線（2-3 打刻変更申請）を §7 に明記、または「開き working を持つ対象は roster に含める」例外を検討。
- **record_history(organization:)**: `operator.organization`（with_tenant ルート）を明示渡し（target_user/record 由来と取り違えない・§4.14「付随表にも organization_id 明示」）。
- **note の信頼度**: 表示の一次ソースは構造化 `actor_id`。note prose の operator 名 `；` 連結は補助（同一テナント hr_admin の name 由来 `；` で断片境界偽装の余地・XSS は Rails 既定エスケープで防御済）。
- **UI 実装注意**: `button_to` は単一ボタンの最小 form で sibling `<select>` を内包不可。行ごと `form_with` + reason select + 出勤/退勤の 2 submit（formaction）で実装。
- **record_history の置き場**: 「private 共有ヘルパ」は別クラス 2 つで共有不可。`Clockings.record_history(...)` module メソッド（`snapshot_pattern_id`/`append_note` と同列）に確定。

### R-14【整合】hr_admin 拡張の扱い（YAGNI 指摘への応答）
YAGNI 視点は「hr_admin 拡張は唯一の仕様超過・削る寄り/SPEC 先固定」と指摘。**ユーザー決定で hr_admin 可を採用**ゆえ、SPEC §3.4(line 211) を「代理打刻 = manager(直接部下) + hr_admin(全員)」へ**要件として amend**（§8）。広い権限は actor 必須（R-9）＋不変監査＋本人バナー（R-6）で牽制する旨を設計意図に残す。

### R-15【整合】§0↔§1 の event_type 表現・スキーマ非対称の carve-out 明記
- §0「整数を予約しコメント温存」は AR.status 流の非宣言予約を想起させるが、event_type は §4.14 が全 9 を順序固定する taxonomy ゆえ**全宣言が正**。§0 を「event_type は全 9 を enum 宣言・未使用分はコメントで明示（status とは扱いを変える＝固定 taxonomy・behavior 無し）」と読み替え。
- `attendance_histories` 完全形 ↔ `attendance_records` 消費分のみ、の非対称の根拠を明文化:「**trigger 保護された append-only 表への後続 ALTER（＋関数再ダンプ）は高摩擦**ゆえ完全形を一度で建てる（消費分のみ原則の意図的 carve-out）」。

## §0' 実装順（writing-plans への申し送り）

> 各タスクは完了条件に検証コマンド（`bundle exec rspec`・`rubocop --force-exclusion`・app 触れたら `bin/brakeman`）を明記。ステップ完了ごと即コミット。

1. **fx 導入 + `attendance_histories` + 関数/3 トリガー**。**ハード完了ゲート（§R-2/R-3/R-5）**: exclusion constraint（既存 user_work_patterns）**と**新トリガーを**同一 schema.rb** に含めた状態で `db:schema:dump → db:test:prepare(load) → 拒否 spec 緑` のラウンドトリップ（関数→トリガーのロード順含む）。CI ロールの `CREATE FUNCTION/TRIGGER` 権限確認。
2. `AttendanceHistory` モデル + 3 段不変防御 + 同一テナント検証（user/actor/source・R-1/R-2）+ actor 必須（R-9）+ model spec（AR バイパス全経路・requires_new 隔離・R-5 が最重要・先に緑へ）。
3. `attendance_records` カラム追加 + enum + 共有部品抽出（`snapshot_pattern_id`/`append_note`/`record_history`/`recalculate_safely`・ClockIn/ClockOut リファクタ回帰・R-4）。
4. `ProxyClockIn`/`ProxyClockOut` サービス + service spec（tx 境界・cross_tenant/self_proxy/reason_required fail-closed・rescue 外出し assert・R-4/R-7/R-8）。
5. Policy + Controller + ルート + policy/request spec（scope 外 404・hr_admin/manager 境界・R-13 inactive/IDOR）。
6. UI（行 form_with ロスター・**本人ホームの代理打刻バナー R-6**・ナビ・i18n）+ system spec。
7. docs 逆反映（SPEC §4.14 actor_id/二軸/整数凍結/§7.6 復元契約・§3.4 権限 amend・§6.8 導線・§11.1 計算値解決・ROADMAP・RAILS_GOTCHAS・NOTES #17）→ `/preflight` → PR。

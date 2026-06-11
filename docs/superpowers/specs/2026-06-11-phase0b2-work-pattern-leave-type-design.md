# Phase 0b-2（WorkPattern + LeaveType）設計仕様

- 日付: 2026-06-11（多視点レビュー反映済み: 原則整合・実用主義・YAGNI・テナント分離・テスト網羅・**労務法令**の 6 視点並列）
- 対象: ROADMAP Phase 0b-2。WorkPattern / LeaveType の CRUD・法定休憩バリデーション（労基法 34 条 1 項）・night_shift×flextime 警告 + 追加スコープ（dev seed・タブ active 修正・i18n）
- 上位文書: [docs/SPEC.md](../../SPEC.md)（§4.4・§4.5・§12.3）/ [docs/ROADMAP.md](../../ROADMAP.md) / [docs/RAILS_GOTCHAS.md](../../RAILS_GOTCHAS.md)
- 法令出典: 労基法 <https://laws.e-gov.go.jp/law/322AC0000000049>（34 条 1 項は設計段階で jp-labor-evidence により原典照合済み・2026-06-11）
- 前提: Phase 0b-1 の Admin 資産（BaseController 外殻ゲート・NavComponent・policy_scope 経由 find・303 redirect・enum validate 規約）

## 0. スコープと確定済み判断

| 論点 | 決定 |
|---|---|
| 削除方針 | **無効化のみ**（User と同型: `active=false`・destroy ルートなし）で全マスタ統一。参照登場時の削除ガード追加という将来作業を構造的に消す |
| 実装形 | **案 C: 同型の共通化は 2 点のみ** — `Admin::Deactivatable` concern（User 移行込みで同型 3 例・Rule of three 成立）と `Admin::MasterPolicy` 基底。**基底の継承は現時点 2 つ（WorkPattern/LeaveType）で、UserPolicy とは同文重複を意図的に温存する**（招待条件を持つ UserPolicy を「マスタ」概念に結合させない。0b-3 CompanyCalendar = import あり・0b-5 OrganizationSetting = singleton という異型が控えるため、基底は「素の CRUD マスタ」だけに限定）。汎用マスタコントローラ（メタプログラミング）は YAGNI + §2.2-5 の趣旨により不採用 |
| 追加スコープ | ①dev seed に初期マスタ ②タブ active 表示修正（バックログ回収） ③i18n（バックログ回収） |
| i18n 深度と同居 | **rails-i18n + devise-i18n の標準 gem 2 つ**（悲観固定）+ 手書きは ja.yml 最小。`default_locale = :ja`。**0b-2 に同居**（先行分割案は、既存 spec への波及が実測 2 ファイル 6 行と確定したため便益が薄い — §5） |
| 法定値の置き場 | 労基法 34 条 1 項の最低休憩は **WorkPattern モデル内の deep freeze 定数**（テナント設定で改変不可・SPEC §4.15 の原則をマスタに適用）。現時点の消費者はモデルバリデーションのみで、複数消費者（Phase 1/4 の実労働ベース再判定等）が現れた時点で共有定数モジュールへの移設を検討 |

**0b-2 の範囲外（理由付き）:**
- UserWorkPattern 割当（0b-4）・CompanyCalendar（0b-3）
- `standard_work_hours` と start/end/break の計算整合チェック（SPEC §4.4 は独立入力として定義。必要になれば警告表示を後付け）
- LeaveType の system_type×paid_leave 整合制約（SPEC に無し・YAGNI。ただし `annual` かつ `paid_leave=false` のマスタは §8.6 の有給 5 日義務判定に影響し得るため、**Phase 4 着手時に整合警告を再検討**）
- **インライン編集（SPEC §12.3）**: ページ遷移型 edit で機能要件は満たす。Turbo 化は UX 改善として横断バックログへ（ROADMAP に追記）
- **割当済み WorkPattern の無効化ガード**（User ガード②と同型の論点）: 参照テーブルが 0b-4 で登場するため、**判断の所在を ROADMAP 0b-4 行に注記**して送る
- **実労働時間ベースの休憩再判定**: 34 条の義務は所定でなく当日の実労働時間に掛かる（所定 8h・休憩 45 分は適法保存できるが残業 1 分で 60 分必要）。マスタ検証は必要条件であって十分条件でない。Phase 1/4 の事後アラート（打刻ブロック不可・§8 原則)として横断バックログ + 社労士確認 #8

## 1. 構成

```
db/migrate/xxx_create_work_patterns.rb          # 複合 unique・FK・NOT NULL（§2）
db/migrate/xxx_create_leave_types.rb            # 同上（§3）
app/models/work_pattern.rb                      # acts_as_tenant・法定休憩・実効値メソッド・mode_conflict?
app/models/leave_type.rb                        # acts_as_tenant・system_type enum (validate: true)
app/policies/admin/master_policy.rb             # hr_admin 限定 CRUD の共通基底（新設）
app/policies/admin/{work_pattern,leave_type}_policy.rb  # 基底を継承するだけ（spec は個別に張る）
app/controllers/concerns/admin/deactivatable.rb # deactivate/activate（User からも移行）
app/controllers/admin/{work_patterns,leave_types}_controller.rb
app/views/admin/work_patterns/ , leave_types/   # index/show/new/edit/_form（個別）
app/components/admin/nav_component.*            # タブ 3 つ + active 判定を start_with? へ
config/locales/ja.yml                           # §5
app/views/devise/sessions/new.html.erb          # 生成 + 日本語化
app/views/devise/unlocks/new.html.erb           # 生成 + 日本語化（lockable 有効・gem 既定は英語）
app/views/devise/mailer/reset_password_instructions.html.erb  # 日本語本文（招待の自己救済導線で踏む）
db/seeds.rb                                     # 初期マスタ（冪等）
Gemfile                                         # rails-i18n / devise-i18n（悲観固定）
docs/SPEC.md §4.4                               # 補強 2 点の逆反映（§8 手順）
```

- ルーティング: `namespace :admin` に `resources :work_patterns, except: :destroy` / `resources :leave_types, except: :destroy`（member patch: deactivate / activate）
- **`Admin::Deactivatable` の契約（3 行で固定 — メタプログラミングへの逆戻り禁止）:**
  1. concern はフック `def deactivatable_record = raise NotImplementedError` のみを持ち、**finder を一切持たない**（fail-closed。各コントローラの `set_*`（policy_scope 経由 find）が実装する）
  2. redirect は `redirect_to [:admin, record], status: :see_other`・notice/alert は `record.name` + `errors.full_messages.join("。")`（現 UsersController と同文）
  3. User 移行の合格条件: 既存 user 系 spec 無修正 green **+ 移行と同時に user 側へ 3 example 追補**（失敗経路の status 303・redirect 先 location・activate の IDOR 404 — 既存 spec の検知穴を塞ぐ。§7）
- `Admin::UserPolicy` は MasterPolicy を継承しない（§0）

## 2. WorkPattern モデル

### スキーマ（SPEC §4.4）

name(string NOT NULL) / start_time・end_time(time NOT NULL) / break_minutes(integer NOT NULL) / standard_work_hours(decimal(4,2) NOT NULL・24.00 まで表現可) / night_shift・flextime(boolean NOT NULL default false) / core_time_start・core_time_end(time null 可) / morning_half_break_minutes・afternoon_half_break_minutes(integer null 可) / active(boolean NOT NULL default true)。

migration は users の先例と同型で:
- `t.references :organization, null: false, foreign_key: true`
- 複合 unique `(organization_id, name)`
- `add_index :work_patterns, [:organization_id, :id], unique: true` — **複合 FK の前提となる unique index（このカラム順が必須）** のコメントを users migration から転記（順序逆転は 0b-4 で初めて発火する遅延バグ）

### 法定休憩バリデーション（労基法 34 条 1 項・原典照合済み）

```ruby
# 労基法 34 条 1 項の法定値（テナント設定で改変不可・SPEC §4.4/§4.15）。
# 検証するのは同項の「量的下限」のみ — 「労働時間の途中に」（位置）・34 条 2 項（一斉付与）・
# 3 項（自由利用）はスキーマ上検証不能で対象外。
# 降順必須（first-match で判定するため、順序を入れ替えると 8h 超が 45 分で valid になる）
LEGAL_BREAK_REQUIREMENTS = [
  { over_hours: 8, min_break_minutes: 60 }.freeze,  # 8 時間「超」→ 60 分以上
  { over_hours: 6, min_break_minutes: 45 }.freeze,  # 6 時間「超」〜8 時間以下 → 45 分以上
].freeze   # deep freeze — 外側だけでは内側 Hash が実行時に改変可能
```

- 判定は「**超**」: 6h ちょうどは休憩 0 で適法・8h ちょうどは 45 分で適法（原典の「六時間を超える場合においては少くとも四十五分、八時間を超える場合においては少くとも一時間」と一致確認済み）
- **エラーは `errors.add(:base, ...)`** に SPEC §4.4 の文言そのまま（属性に付けると i18n 後の full_message で属性名が前置され文言が壊れるため）
- **フル勤務**: `standard_work_hours` vs `break_minutes`
- **半休**: 半休所定 = `standard_work_hours / 2`（**近似** — 実際の午前/午後所定は休憩位置により非対称になり得るが、SPEC §4.4 の定義に従う。45 分閾値に掛かるのは standard > 12h の場合のみで実害は僅少）。休憩は**実効値メソッド**で判定:

```ruby
# null → break_minutes/2 のフォールバックを単一ソース化。
# Phase 1 の WorkTimeCalculator 入力合成（SPEC §5.1 の同一規則）もこのメソッドを参照すること
def effective_morning_half_break_minutes = morning_half_break_minutes || break_minutes / 2
def effective_afternoon_half_break_minutes = afternoon_half_break_minutes || break_minutes / 2
```

### その他のバリデーション

- presence: name / start_time / end_time / break_minutes / standard_work_hours、`validates_uniqueness_to_tenant :name`
- numericality: break_minutes ≧ 0（整数）/ standard_work_hours > 0 かつ ≦ 24 / half break minutes は null 可・指定時 ≧ 0
- **SPEC に無い補強 2 点（採用にあたり SPEC §4.4 へ逆反映する — §8 手順）:**
  1. `flextime: true` なら `core_time_start/end` presence + コアタイム順序は非夜勤のみ `start < end` を強制（夜勤フレックスは日跨ぎコアタイム可・`start == end` の縮退は常時拒否）— 実装時に判明した time 型ダミー日付の制約による（§5.4 の遅刻早退判定がコアタイム基準 — 判定不能データを書き込み時に止める。スーパーフレックス運用を将来許す場合は §5.4 ごと改訂）。`flextime: false` での core_time 残存は許容（無視される値・拒否しない）
  2. `night_shift: false` なら `start_time < end_time`（§5.1 の翌日換算は night_shift かつ start > end が前提。逆転データは負の労働時間を生む）。**night_shift: true の start > end（夜勤の典型）は valid** — この鏡像 spec が無いと「条件なし逆転拒否」の誤実装で夜勤が保存不能になる（§7）
- **night_shift × flextime**: 保存許可。`mode_conflict?` を一覧・詳細・フォームの警告バッジに使う

## 3. LeaveType モデル

- スキーマ（SPEC §4.5）: name(string NOT NULL) / system_type(integer NOT NULL) / allow_half_day・paid_leave(boolean NOT NULL default false) / description(text null 可) / active(boolean NOT NULL default true)。migration は WorkPattern と同型（複合 unique 2 本 + カラム順コメント）
- `enum :system_type, { annual: 0, substitute_holiday: 1, compensatory_leave: 2, child_care: 3, paternity_leave: 4, other: 5 }, validate: true`
- presence: name / system_type、`validates_uniqueness_to_tenant :name`

## 4. 認可・コントローラ

```ruby
module Admin
  class MasterPolicy < ApplicationPolicy   # 素の CRUD マスタ専用基底（§0 の限定参照）
    def index? = hr_admin?
    def show? = hr_admin?
    def create? = hr_admin?
    def update? = hr_admin?
    def deactivate? = hr_admin?
    def activate? = hr_admin?

    class Scope < ApplicationPolicy::Scope
      # 組織のマスタ全件（inactive 含む）。organization_id 明示 = without_tenant 文脈の
      # fail-open 遮断（user_policy と同型の二重防衛）
      def resolve = scope.where(organization_id: user.organization_id)
    end

    private

    def hr_admin? = user.hr_admin?
  end
end
```

- コントローラは UsersController と同型: 全アクション record authorize・index は `policy_scope` + `order(:name)`・**permit はマスタ属性のみ（`active` / `organization_id` は permit しない** — active は member アクション専用・organization_id は acts_as_tenant が代入）

## 5. i18n

- Gemfile: `gem "rails-i18n", "~> 8.0"`（8.1.0 が解決・railties >= 8.0）/ `gem "devise-i18n", "~> 1.15"`（1.16.0 が解決・devise >= 5.0.0 対応版）
- `config.i18n.default_locale = :ja`
- `config/locales/ja.yml`（手書き最小）:
  - `activerecord.models`（organization=組織・user=社員・work_pattern=勤務パターン・leave_type=休暇種別）
  - `activerecord.attributes`（3 モデルの全カラム）
  - **`leave_type.system_types`（enum 値の表示名**: annual=有給休暇・substitute_holiday=振替休日・compensatory_leave=代休・child_care=育児休業・paternity_leave=産後パパ育休・other=その他**）+ 表示ヘルパ**（出荷画面に英語 enum を露出させない）
  - `devise.mailer.invitation_instructions.subject: 【Gatcha】アカウント登録のご案内`
- **devise ビューの残存英語面を一掃**: sessions/new（submit "Log in" がハードコード）・unlocks/new（lockable 有効）を生成 + 日本語化、reset_password_instructions メーラー本文を日本語で作成（招待の期限切れ自己救済導線でユーザーが普通に踏む — 件名だけ日本語で本文英語の混在を防ぐ）。passwords と同じ直書きスタイル
- **既存 spec への波及は実測済みで 2 ファイル 6 行に閉じる**（admin_invitation_spec.rb:14-16・tenant_isolation_spec.rb:19-21 の `fill_in "Email"` / `"Password"` / `click_button "Log in"`）。devise flash の英語文言 assert は spec 内にゼロ件・`errors[:attr]` 系 assert は属性名を含まないため不変。全 suite 実行は**確認手段**（洗い出し手段ではない）
- 時刻表示は `strftime("%H:%M")` に統一（time 型の 2000-01-01 ダミー日付を露出させない）。spec の時刻比較も文字列で行う

## 6. seed・タブ

- seeds（各組織の `with_tenant` 内・`find_or_create_by!(name:)` で冪等）:
  - WorkPattern: 日勤（9:00–18:00・休憩 60・8h）/ 夜勤（22:00–7:00・night_shift・休憩 60・8h）/ フレックス（9:00–18:00・flextime・core 10:00–15:00・休憩 60・8h）— いずれも本設計の全バリデーションを充足することを確認済み
  - LeaveType: 有給休暇（annual・paid_leave・半休可）/ 慶弔休暇（other）/ 振替休日（substitute_holiday）/ 代休（compensatory_leave）
- NavComponent: タブ 3 つ（社員・勤務パターン・休暇種別）。active 判定を `helpers.request.path.start_with?(path)` へ（バックログ回収）

## 7. テスト（/gen-spec 規約 + 偽テスト防止 4 規約）

**model（両モデル）**: 3 点セット（テナント内 unique・鏡像・`save!(validate: false)` → `RecordNotUnique`）。

**WorkPattern 固有（example 列挙）**:
- 法定休憩の境界 6 象限（6h ちょうど 0 分 valid / 6h 超 44 invalid・45 valid / 8h ちょうど 45 valid / 8h 超 59 invalid・60 valid）— **invalid 側は `errors[:base]` の SPEC 文言一致まで assert**（別バリデーション起因の偽 green 防止）
- 半休: **standard_work_hours 13（半休 6.5h でしか発火しない）** で half break 明示 44 invalid / 45 valid・**null で break_minutes 88 invalid（実効 44）/ 90 valid（実効 45）**・午前のみ invalid で午後は独立
- flextime: core 欠落 invalid・**core_time_start ≧ core_time_end invalid**・揃って valid
- night_shift: **false × start ≧ end invalid / true × start > end valid（夜勤の鏡像 — 必須）**
- numericality 負例（break_minutes 負数・standard_work_hours 0 と 24 超・half break 負数）
- `mode_conflict?` / 実効値メソッドの null フォールバック

**LeaveType 固有**: enum validate（不正値 invalid）。

**policy（個別 policy に張る — 基底変更の波及検知）**: permit_actions / forbid_actions を **user_policy_spec と同粒度（index show new create edit update deactivate activate）** で。destroy? deny。Scope は inactive 含む + 他テナント漏れなし + **`ActsAsTenant.without_tenant { resolve }` が自組織のみ返す**（organization_id 明示の fail-open 検出 — test_tenant 下の spec では検知できない）。

**request（両リソース）**:
- CRUD・未認証 redirect・403 対照ペア・**IDOR は show/edit/update/deactivate/activate の全 member アクション × 404**・DELETE ルート不在
- enum 不正値 422・バリデーション違反 422 + 状態不変・**失敗経路も status（303/422）と redirect 先 location まで assert**
- permit 境界（`active` / `organization_id` を送っても無視）
- mode_conflict の警告バッジ: index/show で「conflict パターンは警告文言を含む / 非 conflict は含まない」の対照ペア

**user 側の追補（concern 移行と同時・既存 spec の検知穴 3 つ）**: deactivate/activate 失敗経路の status 303・redirect 先 location・activate の IDOR 404。

**seeds**: `Rails.application.load_seed` を 2 回実行して件数不変・例外なし（冪等性 + 夜勤/フレックス seed が新バリデーションを通る検証を兼ねる）。

**NavComponent**: 「/admin/users/123 で社員タブが active・他タブは非 active」の対照（component spec or request body assert）。

**i18n**: 効果 example 2 本 — **新モデル属性由来の full_message**（例: name presence →「パターン名を入力してください」— ja.yml の手書きキーを実際に踏む）+ 招待メール件名。既存 6 行の日本語ラベル化。ついでに admin_users_spec.rb:89 の `body.encoded` を `body.decoded` へ（RAILS_GOTCHAS 規約違反の既存残骸）。

system spec の新規追加はしない（CRUD は request で十分・E2E は既存の招待一周がナビ経路を兼ねる）。

## 8. 実装後の確認・SSOT 逆反映

- **SPEC §4.4 へ補強 2 点を追記**（flextime 時 core_time 必須・night_shift=false 時 start < end）— 本スライスの PR に含める（`/spec-check` の偽陽性防止）
- **ROADMAP**: 0b-2 行 + 横断バックログ 2 件（タブ active・i18n）のチェック。バックログへ追加 3 件 — インライン編集（§12.3・Turbo 化）・実労働ベース休憩再判定（Phase 1/4・社労士 #8 連動）・`annual×paid_leave=false` の整合警告（Phase 4）。**0b-4 行に「割当済み WorkPattern の無効化ガード要否（User ガード②と同型）」を注記**
- `tenant-isolation-reviewer`（新モデル 2 + policy 基底 + concern）
- `labor-law-compliance-reviewer`（34 条は設計段階で原典照合済み — 実装の数値・文言が設計とズレていないかの確認）
- docs/LABOR_LAW_REVIEW_NOTES.md に #8（実労働ベース再判定）・#9（振替休日の事前特定）を追記済み（本設計と同じ PR）

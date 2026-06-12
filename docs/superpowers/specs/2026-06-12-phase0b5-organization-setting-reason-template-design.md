# Phase 0b-5（OrganizationSetting + ReasonTemplate）設計仕様

- 日付: 2026-06-12（多視点レビュー反映済み: 原則整合・実用主義・YAGNI・テナント分離・**労務法令**の 5 視点並列）
- 対象: ROADMAP Phase 0b-5。組織設定画面（v1 最小）・申請理由テンプレート CRUD・fiscal_year_end_month 変更時の CompanyCalendar.fiscal_year 再計算（0b-3 設計 §0 の宿題回収）
- 上位文書: [docs/SPEC.md](../../SPEC.md)（§4.15・§4.16・§16.7）/ [docs/ROADMAP.md](../../ROADMAP.md) / [docs/RAILS_GOTCHAS.md](../../RAILS_GOTCHAS.md)
- 前提: 0b-1〜0b-4 の Admin 資産（BaseController・MasterPolicy・Deactivatable・policy_scope 経由 find・303/422 規約・`Organization#today`）

## 0. スコープと確定済み判断

| 論点 | 決定 |
|---|---|
| fiscal_year 再計算 | **変更保存と同一 tx で自動再計算**（全 CompanyCalendar を `find_each { save! }` — 0b-3 の `set_fiscal_year` が date から毎回再導出するため保存を通すだけで成立。update_all/update_column はバリデーション・コールバックバイパス規約により不採用）。実変更件数を flash 表示。**Phase 2-2（LeaveBalance）着手時に「残高が存在したら変更禁止へ格上げ」を再判断**（ROADMAP バックログ + SPEC 注記） |
| テーブルスコープ | **消費済みカラムのみ**: `closing_day`（default 31）/ `submit_deadline_days`（default 5）の 2 つ。**SPEC §4.15 の残カラム（通知系・閾値系・36 協定系・integer[]）は消費する Phase の PR が検証・既定値・意味論ごと同梱追加**（ROADMAP 4-1 `email_enabled` 後送りと同方式）。当初案「全カラム + UI 絞り」は 3 視点（YAGNI/労務/原則）の反証 — 毎スライス migration 運用で節約効果ゼロ・法定値と同名同値の 36 協定系カラムは Phase 4-3 実装者が判定で読む誘惑装置・UI 非公開カラムの範囲検証は誤った不変条件を固定化し得る（quiet_hours 19→8 の日跨ぎは正当）— により破棄 |
| 設定行の取得 | **`Organization#setting` アクセサに一元化**（`create_or_find_by!` 形 = `[organization_id]` unique index 前提で SELECT→INSERT 競合を吸収・テナント明示アンカー）。lazy 生成 + seeds + SPEC フォールバック規約の三重保証は過剰 → **読み取りは本アクセサ経由のみ**というアクセサ規約に収斂（SPEC §4.15 へ逆反映）。seeds は dev 用に明示生成を維持 |
| UI 項目 | 編集可 = `fiscal_year_end_month`（Organization 側・SSOT は §4.2 のまま **organization_settings にカラムを作らない**）+ `closing_day` + `submit_deadline_days` の 3 項目 |
| 更新対象の取得 | **`ActsAsTenant.current_tenant` そのインスタンスに固定**（Pragma Critical: acts_as_tenant は organization_id 一致時に DB を読まず current_tenant の in-memory インスタンスを返すため、別インスタンス経由の更新だと `set_fiscal_year` が**旧決算月で再計算して silent failure**。current_tenant 固定なら回避と IDOR 防止を兼ねる）。singular resource で URL に id を持たない |
| サービス抽出 | 2 モデル保存 + 再計算 + 件数集計は `OrganizationSettings::Updater`（PORO・Result 返し）へ（§2.2-2「多段の副作用は Service へ」・0b-3 BulkUpserter 前例）。**内部を `ActsAsTenant.with_tenant(organization)` で自己完結**させ、console/将来ジョブから呼ばれても自社限定を構造保証 |
| ReasonTemplate | 0b-2 LeaveType 同型（無効化のみ・MasterPolicy 継承・Deactivatable 流用）。ただし表示名カラムが `label` のため **`alias_attribute :name, :label`** で Deactivatable の `record.name` 契約に適合（原則レビュー High — 無いと deactivate が NoMethodError 500） |

**0b-5 の範囲外（理由付き）:**
- SPEC §4.15 の残カラム約 17 個（上表の通り消費 Phase へ後送り。36 協定系 4 カラムは **Phase 4-3 で法定定数モジュールと同一 PR** — 「参考閾値 ≤ 法定」検証・DB CHECK・`alert_` リネームの要否をそこで判断。労務レビュー High の条件付き容認）
- UserNotificationPreference（§4.17・Phase 4-1）
- time_zone / 組織名の編集 UI（要求なし・YAGNI）
- 労基法 36 条の原典照合（本スライスに法定値リテラルが入らないため不急。MCP インデックス鮮度注意は NOTES 運用メモ既存）

## 1. スキーマ

```
create_table :organization_settings
  organization_id       bigint  NOT NULL（acts_as_tenant・FK organizations）
  closing_day           integer NOT NULL default 31  # 締め日（31 = 月末・§4.15）
  submit_deadline_days  integer NOT NULL default 5   # 翌月の提出期限（日数）
  timestamps
```

- `[organization_id]` **unique**（テナント毎 1 行の構造保証 = `create_or_find_by!` の前提）+ `[organization_id, id]` unique（プロジェクト規約）

```
create_table :reason_templates
  organization_id  bigint  NOT NULL（acts_as_tenant・FK organizations）
  label            string  NOT NULL   # 管理用識別名（§4.16）
  template_text    string  NOT NULL   # 挿入テキスト
  applies_to       integer NOT NULL   # enum: clock_change(0) / leave(1) / both(2)
  active           boolean NOT NULL default true
  timestamps
```

- `[organization_id, label]` unique（マスタ name 規約と同型）+ `[organization_id, id]` unique

## 2. モデル

**Organization 追補:**

```ruby
has_one :organization_setting, dependent: :destroy

# 設定行の唯一の取得経路（0b-5 設計 §0 — 読み取り側はこのアクセサ規約に従う）。
# create_or_find_by! は [organization_id] unique index 前提で並行初回アクセスの
# SELECT→INSERT 競合を吸収する（属性なし呼び出し = DB 既定値で完結）
def setting
  organization_setting || OrganizationSetting.create_or_find_by!(organization: self)
end
```

**OrganizationSetting:** `acts_as_tenant` 先頭・`validates :closing_day, inclusion: { in: 1..31 }`・`validates :submit_deadline_days, inclusion: { in: 1..28 }`（28 = 2 月の最短月長 — 根拠コメント必須）・`validates :organization_id, uniqueness: true`（DB 例外前のフォームエラー化）。クラスコメントに「§4.15 の残カラムは消費 Phase で追加（0b-5 設計 §0）。法定値は本テーブルに置かない（§4.15 注記）」。

**ReasonTemplate:** `acts_as_tenant` 先頭・`alias_attribute :name, :label`（Deactivatable の `record.name` 契約適合 — コメントで根拠明示）・`enum :applies_to, { clock_change: 0, leave: 1, both: 2 }, validate: true`・`validates :label, presence: true` + `validates_uniqueness_to_tenant :label`・`validates :template_text, presence: true`。

## 3. OrganizationSettings::Updater（サービス）

```
OrganizationSettings::Updater.call(
  organization:,      # ActsAsTenant.current_tenant のインスタンス（コントローラが固定）
  organization_params:,   # { fiscal_year_end_month: }
  setting_params:         # { closing_day:, submit_deadline_days: }
)
→ Result = Data.define(:success?, :recalculated_count, :organization, :setting)
```

1. `organization.assign_attributes` / `setting.assign_attributes` → **`org.valid? & setting.valid?`**（`&&` は短絡して 2 つ目のエラーが集まらない — `&` 必須）。invalid なら failure（両モデルの errors 保持）
2. valid なら `ActsAsTenant.with_tenant(organization)` + tx 内で `save!` × 2
3. `organization.saved_change_to_fiscal_year_end_month?` のとき `organization.company_calendars.find_each { |c| c.save! }` で再計算。**実変更数**は `c.saved_changes.key?("fiscal_year")` でカウント（no-op save は UPDATE を発行しないため保存試行数と実変更数はズレる）
4. 再計算中の `ActiveRecord::RecordInvalid` は rescue して failure（対象日付を errors へ — 設定更新が 500 で死なない 422 合流経路）
5. 注: 再計算は `cal.organization` が current_tenant 短絡（§0）で**更新後の同一インスタンス**を見るため旧値混入なし。N+1 SELECT も同短絡により発生しない（この前提をサービスのコメントに明記）

**update 失敗時の current_tenant 汚染（受容・明文化）:** failure render では organization の dirty 値が in-memory に残るが、設定 edit 再描画の経路で current_tenant の組織属性を計算に使うコードは無い（company_calendars#index の `current_fiscal_year` は別リクエスト）。将来レイアウトが組織属性を計算へ使う場合に再考 — コントローラへコメント。

## 4. ルーティング・コントローラ・Policy

```ruby
namespace :admin do
  resource :organization_setting, only: %i[edit update]   # singular
  resources :reason_templates, except: :destroy do
    member do
      patch :deactivate
      patch :activate
    end
  end
end
```

- `Admin::OrganizationSettingsController < BaseController`
  - `@organization = ActsAsTenant.current_tenant`（params 由来の組織解決経路をコードとして存在させない）・`@setting = @organization.setting`（edit/update 共通の before_action — update 直叩きでも nil にならない）
  - authorize は `[:admin, @setting]` を edit/update で明示。**OrganizationSettingPolicy のクラスコメントに「本ポリシーは設定画面アグリゲート（OrganizationSetting + Organization.fiscal_year_end_month）の認可を所掌」と明文化**（Organization 更新の代理を暗黙から宣言へ — 原則レビュー High）
  - permit は 2 系統・**1〜2 属性に限定**: `params.require(:organization).permit(:fiscal_year_end_month)` / `params.require(:organization_setting).permit(:closing_day, :submit_deadline_days)`。`subdomain`（テナント識別子）・`active`（自社ロックアウト）・`time_zone`・`organization_id` は構造的に不通過
  - 成功: `redirect_to edit_admin_organization_setting_path, status: :see_other`（show なし）+ 実変更数があれば「年度終了月を変更し、会社カレンダー N 件の年度を再計算しました」/ 失敗: `render :edit, status: :unprocessable_entity`
- `Admin::OrganizationSettingPolicy < ApplicationPolicy`（**MasterPolicy 非継承** — singleton 異型は 0b-2 §0 の予告通り個別判断）: `edit? = update? = hr_admin?` のみ。**Scope は定義しない**（index 不在・`verify_policy_scoped` は index のみ強制・誤って policy_scope を呼べば NotDefinedError で fail-closed。安全の補償統制は current_tenant 固定取得に移転 — その旨コメント。将来一覧系を足すなら Scope 必須と明記）
- `Admin::ReasonTemplatesController` / `Admin::ReasonTemplatePolicy < MasterPolicy`: 0b-2 LeaveType 完全同型（policy_scope 経由 find・Deactivatable 流用・permit は label/template_text/applies_to）

## 5. ビュー・ナビ

- `organization_settings/edit.html.erb` — **単一フォーム・別 param キー方式**:
  ```erb
  <%= form_with model: @setting, url: admin_organization_setting_path, method: :patch do |f| %>
    <%# singular resource は polymorphic 解決が壊れるため url: 明示必須（Pragma レビュー High） %>
    <%= fields_for :organization, @organization do |of| %>  <%# トップレベル呼び → params[:organization] %>
      ... fiscal_year_end_month の select 1..12 ...
    <% end %>
    ... f.number_field :closing_day / :submit_deadline_days ...
  <% end %>
  ```
  - 組織情報セクションに説明文「年度終了月を変更すると、登録済み会社カレンダー全件の年度を再計算します」
  - エラー表示は `@organization.errors` + `@setting.errors` の両方を集約描画
- `reason_templates/` 一式（0b-2 leave_types ビュー同型）+ `t_applies_to` ヘルパ + ja.yml（applies_to 3 値: 打刻変更 / 休暇 / 両方）
- ナビ: 「理由テンプレート」「設定」の 2 タブ追加（計 7）

## 6. テスト（/gen-spec 規約）

**model:**
- OrganizationSetting: closing_day/submit_deadline_days の境界（0/1/31/32・0/1/28/29）・organization_id uniqueness（2 行目がフォームエラー）
- Organization#setting: 未生成→生成・生成済み→同一行返却・（DB unique の素通り検証: 2 行目 INSERT で RecordNotUnique）
- ReasonTemplate: enum 毒値 422・label テナント内 unique（鏡像: 他テナント同名 OK）・`name` alias が label を返す

**policy:** OrganizationSettingPolicy（hr_admin 許可 / manager・employee 拒否・edit/update のみ）・ReasonTemplatePolicy（0b-2 同型マトリクス + Scope 2 例）

**request（organization_setting）:**
- 初回 edit で設定行が生成される（lazy）+ 2 回目で件数不変（対照）
- **再計算横断 example（Pragma Critical の唯一の網）**: 実 subdomain 経由で fiscal_year_end_month を 3→12 に変更 → 既存 CompanyCalendar の fiscal_year の**値が実際に変わる**ことを reload で assert + flash に実変更数
- 変更なし（closing_day のみ更新）では再計算スキップ（fiscal_year 不変 + flash に再計算文言なし）の対照
- 失敗 422: organization 側のみ invalid（fiscal_year_end_month: 13）でも両モデルのエラーが表示され入力保持
- **allowlist 形式の permit 境界**（労務レビュー Mid）: 編集可 3 項目**以外**を送っても無視される — organization: subdomain/active/time_zone/name、organization_setting: organization_id（将来カラム追加時に自動で防御対象になる形）
- 403↔200 対照・未認証 redirect

**request（reason_templates）:** 0b-2 同型一式（CRUD・403 対照・IDOR 404・deactivate/activate の flash 文言 = **label が表示されること**で alias を固定）

**seeds:** 設定行 2 組織（`org.setting` 呼び出し）+ テンプレート 2 件（「電車遅延のため」clock_change /「私用のため」both）冪等

## 7. ドキュメント逆反映（PR 同梱）

- **SPEC §4.15**: ①カラム表に「**0b-5 時点の実装は closing_day / submit_deadline_days のみ。残カラムは消費する Phase の PR で追加**（4-1 email_enabled 方式）」の確定記述 ②「設定行の読み取りは `Organization#setting` 経由のみ」のアクセサ規約 ③fiscal_year_end_month 変更時の再計算決定（CompanyCalendar のみ・LeaveBalance/MonthlySummary 出現時は経過措置を再設計）
- **SPEC §16.7-2**: 「既定値で生成」の実装が `Organization#setting`（lazy）+ seeds である旨の注記
- **LABOR_LAW_REVIEW_NOTES #13**: 年度終了月変更と 36 協定対象期間 — 「年 360h/720h/年 6 回の『1 年』の起算日は協定対象期間か会社年度か。期中変更時の短縮年度の按分可否（労基法 36 条 4–6 項は起算を協定記載事項に委ねる）」+ carry_over_limit の適法下限（比例付与者・法定超付与の繰越 — Phase 4-4 カラム追加時の前提）
- **ROADMAP**: 0b-5 行チェック + PR 番号。バックログ追加 2 件 — fiscal_year_end_month 変更禁止への格上げ（**Phase 2-2 着手が再判断トリガー**）・36 協定系カラム追加時の重装備セット（≤法定検証 + DB CHECK + alert_ リネーム + ComplianceService 非参照ガード spec — Phase 4-3）

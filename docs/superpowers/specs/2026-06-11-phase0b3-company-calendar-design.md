# Phase 0b-3（CompanyCalendar）設計仕様

- 日付: 2026-06-11（多視点レビュー反映済み: 原則整合・実用主義・YAGNI・テナント分離・**労務法令**の 5 視点並列）
- 対象: ROADMAP Phase 0b-3。CompanyCalendar の CRUD・CSV 一括インポート（RFC 4180）・`CompanyCalendarResolver`（PORO・未登録日フォールバック §4.7）・legal_holiday 運用
- 上位文書: [docs/SPEC.md](../../SPEC.md)（§4.7・§12.3・§16.7）/ [docs/ROADMAP.md](../../ROADMAP.md) / [docs/RAILS_GOTCHAS.md](../../RAILS_GOTCHAS.md)
- 法令出典: 労基法 35 条 1・2 項（週 1 回 or 4 週 4 日）・39 条 6 項（計画的付与）・26 条（休業手当）<https://laws.e-gov.go.jp/law/322AC0000000049>、平成 6.1.4 基発第 1 号（35% 対象休日の就業規則等による明確化）<https://www.mhlw.go.jp/web/t_doc?dataId=00tb1911&dataType=1&pageNo=1> — いずれも設計段階で jp-labor-evidence により原典照合済み（2026-06-11）
- 前提: Phase 0b-2 の Admin 資産（BaseController 外殻ゲート・MasterPolicy 基底・policy_scope 経由 find・see_other redirect・enum validate 規約・ja.yml）

## 0. スコープと確定済み判断

| 論点 | 決定 |
|---|---|
| CSV 取込方式 | **全件検証 → 上書き upsert**。1 行でもエラーなら全件不採用（行番号付きエラー一覧）。合格時は 1 トランザクションで既存日付を上書き。「再取込すれば最新になる」運用を成立させる |
| upsert の実装形 | **単相**: トランザクション内で `find_or_initialize_by(date:)` → assign → save。既存行は冒頭 1 クエリ（`where(date: dates).index_by(&:date)`）でプリロードし、作成 n/更新 m の集計と find クエリ削減を兼ねる。失敗は行番号付きで収集し `raise ActiveRecord::Rollback`。**事前 valid? の二相方式は不採用**（新規インスタンス検証では上書き対象行が uniqueness で自爆し、正当な再取込を全拒否する） |
| fiscal_year | **date から自動導出**（CSV/フォームでは受け取らない）。導出は `Organization#fiscal_year_for(date)` — Organization が `fiscal_year_end_month` の所有者だから（Phase 2 再利用は結果であって理由にしない） |
| fiscal_year_end_month の SSOT | **Organization（§4.2）を正と宣言**。migration で既存行 backfill(3) → `NOT NULL DEFAULT 3` 化し、コード内 nil フォールバックは置かない（サイレント 3 月締め化の構造的排除）。SPEC §4.15 の同名行へ「§4.2 が正」の注記を本 PR で追記 |
| legal_holiday 運用支援 | **一括生成機能を実装**（期間×曜日 → legal_holiday を BulkUpserter 経由で upsert）+ **35% 保護 3 点セット**（§4 参照）。祝日データはシステム非同梱（CSV 取込のみ・サンプル CSV + 内閣府 CSV 変換手順を画面に記載） |
| CSV の day_type 形式 | **enum キーのみ**（weekday/saturday/sunday/holiday/company_holiday/legal_holiday）。サンプル CSV がテンプレートになるため日本語ラベル両対応は不採用（i18n ラベル改定とインポート互換の暗黙結合を作らない） |
| 削除方針 | **物理削除（destroy）**。§12.3 の「無効化」統一からの意図的逸脱 — カレンダーはイベント参照を持たない日付事実テーブルで active フラグが無意味なため。SPEC §12.3 へ注記を逆反映。締め済み月に属する日付の destroy 制限は Phase 1（締めフロー導入時）に課す将来課題として ROADMAP に注記 |
| サービス構成 | **共通コア + 薄い入口 2 つ**（§1）。CSV と一括生成が「行集合を全件検証して upsert」という同一コアに合流するため。`upsert_all` / `insert_all` は禁止（acts_as_tenant とバリデーションを両方バイパス。性能最適化で移行する場合は organization_id 明示付与 + `unique_by: [:organization_id, :date]` + 値検証の自前実装が条件 — 本設計の制約として明記） |

**0b-3 の範囲外（理由付き）:**
- 割増計算・60h カウント除外・休日労働判定そのもの（Phase 1 以降。本スライスはマスタ整備のみ）
- legal_holiday カバレッジ失効の事前アラート（例: 残り 90 日通知）— 通知基盤は Phase 4-1。index の 0 件バナー（§4）を第一歩とし、本格警告は Phase 4 へ（ROADMAP 横断バックログに追記）
- 4 週 4 日（変形休日制・労基法 35 条 2 項）の起算日管理 — 一括生成フォームは**週休制（毎週特定曜日を法定休日と特定済みの組織）専用**と画面に明記し、4 週 4 日採用組織は CSV 個別登録で対応。v2 課題
- シフト制・交替制の個人別法定休日 — CompanyCalendar は組織単位の単一カレンダー。この限界を SPEC §4.7 に注記（Phase 1 で全社員一律判定の根拠に誤用されることの予防）
- 内閣府祝日 CSV（Shift_JIS・日本語ヘッダ）の直接サポート — 変換手順の記載で代替
- 祝日名の上書き時合成保持（「元日（法定休日）」等）— YAGNI。降格確認（§4）で対象日が見えるため見送り
- fiscal_year_end_month 変更時の既存行 fiscal_year 再計算 — 0b-5（OrganizationSetting）で「再計算 or 変更禁止」を決める宿題として既知の限界を明記

## 1. 構成

```
db/migrate/xxx_change_organizations_fiscal_year_end_month.rb  # backfill(3) → NOT NULL DEFAULT 3
db/migrate/xxx_create_company_calendars.rb       # 複合 unique 2 本・FK・NOT NULL（§2）
app/models/organization.rb                       # fiscal_year_for(date) 追加
app/models/company_calendar.rb                   # acts_as_tenant・enum(validate)・fiscal_year 自動設定
app/services/company_calendars/bulk_upserter.rb  # 共通コア: 全件検証→tx→upsert（§3）
app/services/company_calendars/csv_parser.rb     # CSV→行 hash（行番号付きエラー・4 列ホワイトリスト）
app/services/company_calendars/legal_holiday_rows_builder.rb  # 期間×曜日→行 hash 生成
app/services/company_calendar_resolver.rb        # 読み取り PORO（SPEC §4.7 指定名のため名前空間外）
app/policies/admin/company_calendar_policy.rb    # MasterPolicy 継承 + destroy?/import?/generate?
app/controllers/admin/company_calendars_controller.rb            # CRUD（show なし）
app/controllers/admin/company_calendars/imports_controller.rb    # new/create
app/controllers/admin/company_calendars/legal_holiday_generations_controller.rb  # new/create
app/views/admin/company_calendars/ , company_calendars/imports/ , .../legal_holiday_generations/
app/components/admin/nav_component.*             # タブ「会社カレンダー」追加
public/samples/company_calendar_sample.csv       # 取込テンプレート
config/locales/ja.yml                            # day_types 表示名ほか
db/seeds.rb                                      # 当年度の祝日・legal_holiday（冪等）
Gemfile                                          # gem "csv"（Ruby 3.4 で default gem 外れる時限への先回り）
docs/SPEC.md                                     # §5.5 除外リスト・§4.15 注記・§4.7 限界注記・§12.3 注記（§8）
docs/LABOR_LAW_REVIEW_NOTES.md                   # #10・#11 追記（§8）
docs/ROADMAP.md                                  # 0b-3 行 + バックログ追記
```

- ルーティング（singular resource は**単数形**・コレクション操作なので resources に**ネストしない**）:

```ruby
namespace :admin do
  resources :company_calendars, except: :show
  namespace :company_calendars do
    resource :import, only: %i[new create]
    resource :legal_holiday_generation, only: %i[new create]
  end
end
```

- show なし: 属性 5 個の日付行に詳細画面は無価値（一覧 → edit 直行）。既存マスタとの非対称は意図的
- 書き込み系 redirect は一律 `status: :see_other`・バリデーション失敗 render は `status: :unprocessable_entity`（RAILS_GOTCHAS の Turbo 罠）

## 2. モデル・migration

### organizations 変更

`fiscal_year_end_month` を backfill(3) → `NOT NULL DEFAULT 3`（reversible migration・SPEC §4.15 の既定値を DB 制約へ昇格）。

```ruby
# Organization
# fiscal_year_end_month はオンボーディング（§16.7-1）で設定される前提だが、
# DB 既定 3（§4.15）により未設定でも年度導出は破綻しない
def fiscal_year_for(date)
  start_month = fiscal_year_end_month % 12 + 1
  (date.month >= start_month ? date.year : date.year - 1).to_s
end
```

境界例: 3 月決算 → 2026-03-31 は "2025"・2026-04-01 は "2026"。12 月決算 → 常に `date.year`。

### company_calendars スキーマ（SPEC §4.7）

date(date NOT NULL) / day_type(integer NOT NULL) / name(string null 可) / fiscal_year(string NOT NULL) / counts_as_paid_leave(boolean NOT NULL default **false**)。

migration は既存 3 テーブルと同型で:
- `t.references :organization, null: false, foreign_key: true`
- 複合 unique `(organization_id, date)` — **upsert の衝突キー**（レース時も衝突相手は同一テナント内に限定され、他テナントへの書き込みは DB レベルで不可能）
- `add_index :company_calendars, [:organization_id, :id], unique: true` — 複合 FK の前提 unique index（カラム順必須・users migration のコメントを転記。プロジェクト規約の踏襲）

### CompanyCalendar モデル

```ruby
acts_as_tenant :organization   # ← 宣言順が重要: organization_id 代入は before_validation on: :create で
                               #    宣言時に登録されるため、後続の before_validation から organization を参照できる
enum :day_type, { weekday: 0, saturday: 1, sunday: 2, holiday: 3,
                  company_holiday: 4, legal_holiday: 5 }, validate: true   # CSV 入力直結・RAILS_GOTCHAS 規約

before_validation :set_fiscal_year   # acts_as_tenant 宣言の後に定義（順序依存をコメントで明示）

def set_fiscal_year
  # current_tenant でなく**レコードの organization** から導出（without_tenant 文脈・
  # with_tenant ミスマッチ時に他社の決算月で算出する取り違えを構造的に排除）
  self.fiscal_year = organization&.fiscal_year_for(date) if date
end
```

- presence: date / day_type / fiscal_year（organization 欠落時は fiscal_year presence で 422 に落ちる）、`validates_uniqueness_to_tenant :date`
- `name` は **holiday / company_holiday のみ必須**（祝日名・休業理由。weekday や legal_holiday には不要）
- `counts_as_paid_leave: true` は **company_holiday 以外でバリデーションエラー**（§4.7 の列定義どおり会社休業日専用。暗黙で握りつぶさず明示エラー）。フォームでは company_holiday 以外選択時に checkbox を disable
- `legal_holiday` と `sunday` の排他（§4.7）は単一 enum カラムにより構造的に保証

## 3. サービス層

### CompanyCalendars::BulkUpserter（共通コア）

- **コンストラクタで `organization:` を明示要求**し、内部を `ActsAsTenant.with_tenant(organization)` でラップ。nil は `ArgumentError`（without_tenant 文脈 = seed・rake・console での fail-open を**サービス側ガード**で遮断。「呼び出し側が with_tenant する規約」に依存しない — RAILS_GOTCHAS の fail-open 台帳と同根）
- 入力: 行 hash の配列（date / day_type / name / counts_as_paid_leave の 4 キーのみ。**入口共通で 2,000 行上限** — CSV 経路専用にしない）
- 処理: tx 内で既存行プリロード → 各行 `find_or_initialize_by(date:)` → assign → save。1 件でも失敗なら全エラー収集後 Rollback
- **降格検出**: 既存 `legal_holiday` 行を別 day_type へ変更する行は、`allow_demotion: true` が渡されない限り**エラー扱い**（行番号 + 対象日明示）。35% 付け漏れ方向（賃金未払リスク）の変更だけ非対称に守る。祝日→legal_holiday 等の労働者有利方向はそのまま通す（§4.7 の「25% フォールバックを採らない」原則と同方向）
- `rescue ActiveRecord::RecordNotUnique` → 行エラー化（並行インポートの TOCTOU を 500 にしない）
- 戻り値: Result（`success?` / `errors`（行番号付き）/ `created_count` / `updated_count`）

### CompanyCalendars::CsvParser

- 検証順序（DoS 緩和のため**パース前に**遮断）: ①`ActionDispatch::Http::UploadedFile` 型チェック（multipart でない String/nil で 500 にしない）→ ②1MB バイト上限（パース前メモリガード）→ ③UTF-8 検証（BOM 許容・他エンコーディングは「UTF-8 で保存し直す」案内エラー）→ ④Ruby 標準 `CSV` でパース（`CSV::MalformedCSVError` rescue → 行番号付きエラー）
- ヘッダ必須（date / day_type 必須列・name / counts_as_paid_leave 任意列）。**読み取りは 4 列のみ**で他列は無視 — `organization_id` / `fiscal_year` / `id` 列が混入しても受理しないホワイトリスト（CSV はstrong params を通らないため、ここが mass-assignment 防壁の代替）
- 行検証: date は `Date.iso8601`、day_type は enum キー 6 値、counts_as_paid_leave は true/1/false/0/空（空 = false）。**CSV 内の日付重複もここで検出**
- 2,000 行上限（行数 = 妥当性ガード。実需は 1 年 366 行・5 年分 1,830 行）

### CompanyCalendars::LegalHolidayRowsBuilder

- 入力: start_date / end_date / 曜日（**既定なしの必須選択** — 日曜既定は就業規則と不一致のままの誤クリック確定を誘発するため）
- 検証: start ≦ end・**期間上限 2 年**（≒105 行。行数爆発と「長期間登録による失効の先送り」の両方を抑止）
- 出力: 該当曜日の行 hash（`day_type: legal_holiday, name: "法定休日"`）→ BulkUpserter へ（上書きルール共通）

### CompanyCalendarResolver（SPEC §4.7 指定名のため `CompanyCalendars::` 名前空間外）

- **コンストラクタで `organization:` を明示要求**（BulkUpserter と同じ fail-open ガード）
- `day_type(date)` — 登録行があればその day_type、なければ `Date#cwday`（ISO 曜日番号・ロケール非依存）で 1〜5 → `:weekday`、6 → `:saturday`、7 → `:sunday`
- `registered?(date)` — 登録由来かフォールバック由来かの判別（**Phase 1 の「未特定の休日労働は 35% 側 or 警告」実装の手がかり** — 労務レビュー指摘。フォールバック `:sunday` を所定休日と断定させない）
- `day_types(from, to)` — 登録行を 1 クエリでロードし、**範囲内の全日付**（未登録日はフォールバック解決済み）の `{ date => day_type }` を返す一括 API（月次計算の N+1 を防ぎ、Phase 1 で unscoped/生 SQL へ逃げる誘因を残さない）
- **境界の規約**: Resolver は AR 依存であり §2.2-1 の calculators（値→値・DB なしテスト）には置けない。**Phase 1 では入力合成層（service/job）が Resolver を呼び、calculator へは day_type を値として渡す**（calculator 内部から呼ばない — コードコメントで明示）

## 4. 認可・コントローラ・UI

```ruby
module Admin
  class CompanyCalendarPolicy < MasterPolicy   # 素の CRUD 部分は基底を再利用
    def destroy? = hr_admin?                    # 基底に無い 3 メソッドだけ追加（§12.3 逸脱は §0 参照）
    def import? = hr_admin?
    def generate? = hr_admin?
    # Scope は基底の organization_id 明示（without_tenant fail-open 遮断の二重防衛）をそのまま継承
  end
end
```

- CompanyCalendarsController: WorkPattern と同型（全 action authorize・policy_scope 経由 find の一本道・permit は date / day_type / name / counts_as_paid_leave のみ — organization_id / fiscal_year は permit しない）
- Imports / LegalHolidayGenerations コントローラ: レコード不在のため**クラス authorize**（`authorize [:admin, CompanyCalendar], :import?` / `:generate?`）。file param はモデル属性でないため permit 不要（防壁はパーサのホワイトリスト — §3）
- **index**: 年度フィルタ（既定 = 今年度・`Organization#fiscal_year_for(Date.current)`）付きフラットテーブル（日付・曜日・day_type バッジ・名称・有給算入）。**表示年度に legal_holiday が 0 件なら警告バナー**（35% 保護 3 点セットの①。「§4.7 により法定休日の登録は必須運用」の旨 + 一括生成への導線）
- **imports/new**: file field + フォーマット説明 + サンプル CSV リンク（public/ 静的配置 — 秘匿性ゼロのため send_file は過剰）+ 内閣府祝日 CSV（Shift_JIS）→ UTF-8/enum キー変換手順 + **「既存 legal_holiday の変更（降格）を許可する」checkbox**（3 点セットの②。未チェック時は該当行エラー — §3 の `allow_demotion`）
- **legal_holiday_generations/new**: start/end date・曜日必須選択 + 注意文 2 点（3 点セットの③）: 「就業規則上の法定休日の定めと一致させること」（平成 6.1.4 基発第 1 号の明確化要請）・「本フォームは週休制専用。4 週 4 日制（労基法 35 条 2 項）の組織は CSV で個別登録」+ 既存登録上書きの警告
- counts_as_paid_leave のフォームヘルプ: 「会社休業日を有給消化として扱うには計画的付与の労使協定等の根拠が必要（労基法 39 条 6 項）」（社労士確認 #10 と連動）
- NavComponent にタブ「会社カレンダー」追加（active 判定は既存の start_with? 方式のまま）

## 5. i18n・seed

- ja.yml: `activerecord.models.company_calendar`（会社カレンダー）・attributes 全カラム・**`company_calendars.day_types.*` 表示名**（weekday=平日・saturday=土曜・sunday=日曜・holiday=祝日・company_holiday=会社休業日・legal_holiday=法定休日）+ 表示ヘルパ（LeaveType の `t_system_type` と同じ流儀。出荷画面に英語 enum を露出させない）
- seeds（各組織の `with_tenant` 内・`find_or_create_by!(date:)` で冪等）: 当年度の国民の祝日（数件で可・全件は不要）+ 日曜の legal_holiday 数週分 — §16.7-4 のオンボーディング動作確認と Resolver の手動確認を兼ねる

## 6. テスト（/gen-spec 規約 + 偽テスト防止）

**Organization**: `fiscal_year_for` の境界（3 月決算: 3/31 → "2025"・4/1 → "2026" / 12 月決算: 常に当年 / 1 月決算）。migration 後の NOT NULL/default の検証は schema 由来のため不要。

**CompanyCalendar model**: 3 点セット（テナント内 date unique・鏡像 = 他テナント同日 valid・`save!(validate: false)` → `RecordNotUnique`）・enum validate 不正値・name 必須の対照（holiday は invalid / weekday は valid）・counts_as_paid_leave 相関（company_holiday 以外で true → invalid）・fiscal_year 自動設定（organization 経由・date 変更時の再導出）。

**CsvParser**: 正常系・ヘッダ欠落・date 不正・day_type 不正（日本語ラベルが**エラーになる**ことも 1 例 — 両対応しない決定の回帰防止）・CSV 内日付重複・2,001 行・1MB 超・非 UTF-8・String/nil file・**organization_id 列が無視される**こと。

**BulkUpserter**: 作成のみ / 更新のみ / 混在の n/m カウント・1 行不正で全件不採用（DB 不変まで assert）・**cross-tenant 同一日付**（他テナントに同日行があっても更新せず新規作成・カウント不変）・`organization: nil` → ArgumentError・**`ActsAsTenant.without_tenant` 文脈でも自テナントにのみ書く**・降格検出（legal_holiday → holiday が `allow_demotion` 無しでエラー / 有りで成功・**逆方向の holiday → legal_holiday はフラグ無しで通る対照**）・RecordNotUnique rescue。

**LegalHolidayRowsBuilder**: 曜日抽出・期間上限 2 年超 invalid・start > end invalid。

**CompanyCalendarResolver**: 登録日優先・フォールバック 3 値（cwday 1-5/6/7）・`registered?` の真偽・`day_types` 範囲一括（クエリ数 1 まで assert できれば尚良）・**他テナントの登録日を拾わない**・`organization: nil` → ArgumentError。

**policy**: permit/forbid を user_policy_spec と同粒度（destroy? / import? / generate? 含む）。Scope は MasterPolicy 継承だが**個別に張る**（基底変更の波及検知 — 0b-2 規約）。`without_tenant { resolve }` が自組織のみ。

**request（3 コントローラ）**:
- CRUD: 未認証 redirect・403 対照ペア・IDOR（edit/update/destroy × 404）・**DELETE 成功は 303 + レコード消滅・show ルート不在**・permit 境界（organization_id / fiscal_year を送っても無視）
- import: 正常（作成/更新件数の flash）・エラー CSV 再描画 422 + DB 不変・降格 checkbox の有無対照・file 無し/型不正 422
- 生成: 正常・期間超過 422・曜日未選択 422
- index: 年度フィルタ・legal_holiday 0 件バナーの対照ペア（0 件で表示 / 1 件以上で非表示）

**seeds**: 2 回実行で件数不変・例外なし（冪等 + 新バリデーション通過の検証を兼ねる）。

system spec の新規追加はしない（import の往復は request で十分・E2E は既存の招待一周で代替）。

## 7. SPEC・関連文書への逆反映（本 PR 同梱）

1. **SPEC §5.5**: LeaveDaysCalculator の除外リストに `legal_holiday` を追加（現状は所定休日曜日・holiday・company_holiday(counts=false) のみ — 水曜法定休日の組織で有給が法定休日に充当される誤りの予防。労務レビュー高）
2. **SPEC §4.15**: `fiscal_year_end_month` 行へ「§4.2 Organization が正（DB 既定 3）」の注記（三重既定値の解消）
3. **SPEC §4.7**: 組織単位カレンダーの限界（シフト制の個人別法定休日は v1 非対応）・一括生成は週休制専用（4 週 4 日は CSV 個別登録）の 2 点を注記
4. **SPEC §12.3**: 会社カレンダーは日付事実テーブルにつき物理削除（無効化統一の例外）の注記
5. **LABOR_LAW_REVIEW_NOTES**: #10 counts_as_paid_leave の適法要件（39 条 6 項計画的付与・26 条休業手当との関係・5 日義務カウント可否）/ #11 legal_holiday 一括生成の失効と暦週起算（「週の最後の休日」解釈の原典出典含む）— 労務レビューの文案を採用
6. **ROADMAP**: 0b-3 行チェック + PR 番号。横断バックログへ追記 2 件 — legal_holiday カバレッジ失効の事前アラート（Phase 4・通知基盤接続後）/ 締め済み月の calendar destroy 制限（Phase 1 締めフロー時）。0b-5 行に fiscal_year_end_month 変更時の既存 fiscal_year 再計算判断を注記

## 8. マージ前レビュー

- `tenant-isolation-reviewer`（新モデル + migration + サービス 4 本 — without_tenant ガード・upsert_all 禁止制約・CSV ホワイトリストの実装確認。grep 儀式: `without_tenant` / `upsert_all` / `insert_all`）
- `labor-law-compliance-reviewer` + `/legal-citation-audit`（設計段階で原典照合済み — 実装の文言・SPEC 逆反映がズレていないかの確認）

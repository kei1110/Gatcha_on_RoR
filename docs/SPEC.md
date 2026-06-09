# 勤怠管理 SaaS「Gatcha on Rails」仕様書

> **由来:** 本仕様は Salesforce 2GP パッケージ版 Gatcha（`../Gatcha/docs/SPEC.md`）を Ruby on Rails 向けに再設計したもの。労務コンプライアンスのドメインロジックは一片も削らず、Salesforce 固有の実装制約（ガバナ制限・2GP・Platform Event・LWC・承認プロセス・共有モデル）を Rails のイディオムへ翻訳し直している。
>
> **作成日:** 2026-06-09 / **対象 Rails:** 8.x / **対象 Ruby:** 3.3+

---

## 0. このドキュメントについて

### 0.1 スコープ

- **対象:** 勤怠管理ドメイン（出退勤・休暇・申請承認・月次締め・労務コンプライアンス）= SF 版 `Gatcha` パッケージ相当
- **対象外:** 工数管理（日報・人員配置・予実・SES 精算）= SF 版 `Gatcha Work` パッケージ。別サイクルで設計する。本仕様では「連携の継ぎ目」（§14）のみ定義する
- **成果物:** 本仕様書（設計合意のための SSOT）。実装コードは本サイクルの対象外

### 0.2 SF 版との根本的な違い（再設計の前提）

| 観点 | Salesforce 版 | Rails 版（本仕様） |
|------|--------------|-------------------|
| テナント | 1 社 1 組織（シングルテナント） | **マルチテナント SaaS**（行レベル分離・単一 DB） |
| ユーザー | 標準 `User` オブジェクト | **自前 `User` モデル**（Devise）+ `organization_id` |
| 認可 | OWD + 共有ルール + Permission Set + Path C 5 層 | **テナントスコープ + Pundit ポリシー**（2 層） |
| 配布 | 2GP マネージドパッケージ（AppExchange） | **デプロイ型 SaaS**（「インストール」= 組織オンボーディング） |
| 実装制約 | ガバナ制限（DML 150 / SOQL 50000 / OFFSET 2000 / CPU 10s / Batch 5 / 通知 10/txn） | **制約なし**（通常の DB トランザクション） |

### 0.3 非ゴール

- 給与計算そのもの（基本給・手当・控除・実支給額の算出）。本システムは**勤務実績データ**を提供し、給与システムへの CSV 連携までを担う（労基法 108 条の賃金台帳は給与システムの責務）
- 工数・契約・請求管理（Gatcha Work 領域）
- v1 では時間単位の有給取得（労基法 39 条 4 項）には非対応。データモデルは将来拡張可能な構造を保つ

---

## 1. 製品概要

Salesforce に依存しない、日本の労働基準法・労働安全衛生法に準拠したマルチテナント型勤怠管理 SaaS。複数企業（テナント）が 1 つの Rails アプリを共有し、各社の社員が打刻・休暇申請を行い、管理者が承認・締め・コンプライアンス監視を行う。

### 1.1 主要機能（社員向け）

- 出退勤の打刻（モバイル対応・レスポンシブ / PWA）
- 有給・半休・各種休暇の申請
- 打刻時刻の変更依頼・休日出勤の事前申請
- 月次勤怠レポートの確認・提出・CSV エクスポート
- 個人 TODO・通知設定（オフタイム抑制）

### 1.2 主要機能（管理者向け）

- 部下の勤怠の一覧管理（ダッシュボード）
- 申請の多段階承認（自作承認エンジン）
- 月次締め処理（提出 → 確定 / 差戻し）
- 異常検知アラート（打刻漏れ・過重労働・36 協定・有給 5 日未取得・勤務間インターバル・連続勤務）
- 代理打刻・欠勤確定・産業医面談記録
- マスタ管理（勤務パターン・休暇種別・会社カレンダー・パターン割当・休暇残高）

### 1.3 本システムの本質的価値

単なる打刻記録ではなく、**労働法令違反の予防装置**である。具体的には:

- **正確な割増賃金の根拠データ:** 法定残業 / 所定外残業の二系統、月 60 時間超 50%、深夜帯 25%、法定休日 35%、複合割増（加算方式）を漏れなく算出
- **法的義務の番人:** 有給 5 日取得義務（罰金 30 万円/人）、36 協定上限、勤務間インターバル、連続勤務上限、産業医面談機会の提供を監視・記録
- **完全な監査証跡:** 追記専用ログ（`AttendanceHistory`）で任意時点の勤怠状態を再現可能。労基署調査・5 年保持義務に対応

---

## 2. アーキテクチャ

### 2.1 技術スタック

| 層 | 採用技術 | 備考 |
|----|---------|------|
| 言語 / FW | Ruby 3.3+ / Rails 8.x | モノリス |
| データベース | PostgreSQL 16+ | 行ロック（`FOR UPDATE`）・jsonb・生成列・パーティショニング |
| 認証 | Devise | `User` モデル |
| マルチテナント | acts_as_tenant | 行レベル分離・`organization_id`・`validates_uniqueness_to_tenant` |
| 認可 | Pundit | ロール × テナントスコープのポリシー |
| フロントエンド | Hotwire（Turbo + Stimulus）+ ViewComponent | サーバーレンダリング・レスポンシブ / PWA |
| リアルタイム | Action Cable（SolidCable）+ Turbo Streams | ベル通知 |
| バックグラウンドジョブ | Active Job + **SolidQueue** | `config/recurring.yml` で日次/週次/月次バッチ |
| メール | Action Mailer（`deliver_later`） | 二重 opt-in |
| 状態機械 | AASM | 申請承認・月次締めの状態遷移 |
| CSV | Ruby 標準 `CSV`（ストリーミング応答） | UTF-8 BOM 付・CRLF・RFC 4180 |
| テスト | RSpec + FactoryBot + Capybara | 計算オブジェクトは純粋単体テスト |
| 認可テスト | pundit-matchers | ポリシー網羅 |

### 2.2 設計原則

1. **計算ロジックは純粋オブジェクトへ分離する。** 労働時間・残業・深夜・遅刻早退の計算は `app/calculators/` 配下の AR 非依存な PORO（Plain Old Ruby Object）に切り出す。引数は値（時刻・分・パターン）、戻り値は値。これにより DB なしで網羅的な単体テストが書ける（SF 版では Apex トリガー内に埋もれて検証が困難だった部分）。
2. **複雑な業務ロジックは Service Object へ。** 「休暇承認」「撤回復元」「月次再集計」のような多段の副作用を伴う処理は `app/services/` のサービスクラスにまとめ、トランザクション境界を明示する。軽微な値セット（OwnerId 相当・初期ステータス）のみ AR コールバックを使う。
3. **状態遷移は AASM で宣言的に。** 申請の承認ステータス・月次締めステータスを AASM で定義し、遷移時フック（`after`）で副作用サービスを呼ぶ。SF 版の Mermaid 状態遷移図（§13）がそのまま AASM 定義に対応する。
4. **認可は Pundit に一元化。** SF の OWD/共有ルール/Permission Set/`without sharing`/ElevatedDml の 5 層は、Rails では「**テナントスコープ（acts_as_tenant）+ Pundit ポリシー**」の 2 層に集約される。
5. **ガバナ制限回避の記述を持ち込まない。** 再帰ガード・Bulkification 必須・OFFSET 禁止・Queueable チェーン分割といった SF 固有の回避策は、Rails では不要。大量処理は `find_each` / `insert_all` / `upsert_all` を「必要な箇所だけ」選ぶ設計判断とする。
6. **マルチテナント安全性をデフォルトに。** 全ドメインモデルに `acts_as_tenant(:organization)` を付与。`ApplicationController` で `set_current_tenant_through_filter` によりリクエストごとのテナントを確定し、クロステナント漏洩を構造的に防ぐ。

### 2.3 ディレクトリ構成（主要部）

```text
app/
├── models/            # ActiveRecord モデル（全モデルに acts_as_tenant）
├── calculators/       # 純粋計算オブジェクト（労働時間・残業・深夜・遅刻早退）
│   ├── work_time_calculator.rb
│   ├── overtime_calculator.rb
│   ├── deep_night_calculator.rb
│   ├── late_early_calculator.rb
│   └── leave_days_calculator.rb
├── services/          # 副作用を伴う業務ロジック（承認・撤回・再集計・代理打刻・欠勤確定）
├── policies/          # Pundit ポリシー（ロール × 所有 × テナント）
├── components/        # ViewComponent（ダッシュボード・カレンダー・申請フォーム）
├── jobs/              # Active Job（日次/週次/月次バッチ・通知配信）
├── mailers/           # Action Mailer
└── controllers/
config/
└── recurring.yml      # SolidQueue 定期ジョブ定義
```

### 2.4 名前空間（ドメイン分割）

モデル・サービスは以下のドメイン概念で整理する（物理的な module 名前空間は実装時に判断。本仕様は概念的グルーピング）:

| ドメイン | 含むもの |
|---------|---------|
| **Identity** | Organization, User, ロール, 上長階層 |
| **Masters** | WorkPattern, LeaveType, CompanyCalendar, UserWorkPattern, OrganizationSetting, ReasonTemplate |
| **Attendance** | AttendanceRecord, 計算オブジェクト群 |
| **Leave** | LeaveRequest, LeaveBalance, 有給 5 日義務 |
| **Requests & Approval** | ClockChangeRequest, HolidayWorkRequest, 承認エンジン, 撤回フロー |
| **Closing** | MonthlyAttendanceSummary, 締め状態機械 |
| **Compliance** | 36 協定, 勤務間インターバル, 連続勤務, 産業医面談, 打刻漏れ/欠勤検知 |
| **Notification** | Notification, NotificationDelivery, 抑制設定, 優先度 |
| **Audit** | AttendanceHistory, 保持/アーカイブ |
| **Integration** | ドメインイベント / Outbox（Gatcha Work 連携の継ぎ目） |

---

## 3. マルチテナント・認証・認可（Rails で新規構築）

> SF 版が標準 `User` と OWD/共有/PS で「タダ」で提供していた領域。Rails では自前構築するため、本仕様で最も新規性が高いセクション。

### 3.1 テナントモデル

- **テナント = `Organization`**（導入企業 1 社）。全ドメインモデルが `belongs_to :organization` を持ち、`acts_as_tenant(:organization)` でスコープされる。
- **テナント解決:** `ApplicationController` で `set_current_tenant_through_filter` + `before_action`。解決方式は**サブドメイン**（`acme.gatcha.example.com` → `Organization.find_by(subdomain: 'acme')`）を基本とし、ログイン後は `current_user.organization` でも確定できる二段構え。
- **一意性制約:** テナント内一意は `validates_uniqueness_to_tenant`（例: 同一組織内の社員番号、同一組織・同一ユーザー・同一年度・同一休暇種別の `LeaveBalance`）。
- **DB 制約:** クロステナント漏洩の最終防衛として、複合ユニークインデックスに必ず `organization_id` を含める。外部キーも `(organization_id, ...)` で整合を担保。

```ruby
class AttendanceRecord < ApplicationRecord
  acts_as_tenant(:organization)
  validates_uniqueness_to_tenant :work_date, scope: :user_id
end
```

### 3.2 認証（Devise）

- `User` モデルに Devise（`database_authenticatable`, `recoverable`, `rememberable`, `validatable`, `lockable`, `trackable`, `timeoutable`）。
- `User belongs_to :organization`。1 社員 = 1 組織（複数組織所属は YAGNI として非対応。将来必要なら `Membership` 中間モデルへ拡張）。
- **将来拡張:** 企業の IdP 連携（SAML / OIDC）は OmniAuth で後付け可能な構造を保つ（v1 はパスワード認証のみ）。

### 3.3 ロールと上長階層

SF 版の Permission Set 3 種と `User.IsManagerRole__c`、ロール階層を以下へ集約:

| SF | Rails |
|----|-------|
| AttendanceUser PS | `role: :employee` |
| AttendanceManager PS | `role: :manager` |
| AttendanceAdmin PS | `role: :hr_admin` |
| `User.IsManagerRole__c`（管理監督者・労基法 41 条） | `User#manager_supervisor?`（`exempt_from_overtime` フラグ） |
| ロール階層 / `User.ManagerId` | `User belongs_to :manager, class_name: 'User'`（自己参照 `manager_id`） |

> **重要な区別:** `role`（システム権限：閲覧・操作の範囲）と `exempt_from_overtime`（**管理監督者**：割増賃金の適用除外＝労基法 41 条 2 号の労働法上の地位）は**別概念**。SF 版でも `IsManagerRole__c` は割増計算の分岐に使われ、PS とは独立していた。Rails でも `role` enum と `exempt_from_overtime`（boolean）を分離する。

- `role`: `enum role: { employee: 0, manager: 1, hr_admin: 2 }`
- `manager_id`: 直属上長。承認ルート解決と上長への可視性に使用
- `exempt_from_overtime`: 管理監督者フラグ。割増賃金・60h・法定休日・36 協定の計算で除外（深夜割増は**除外しない**。§8.3 参照）

### 3.4 認可（Pundit）

SF の 5 層防衛（checkPermission + verifyOwner/verifyManager + ElevatedDml + OWD + 共有）は、Rails では **2 層**に簡素化される:

1. **テナント層:** `acts_as_tenant` が `organization_id` で全クエリを自動スコープ（他社データは構造的に不可視）
2. **認可層:** Pundit ポリシーで「ロール × 所有 × 上長関係」を判定

| 操作 | ポリシー判定 |
|------|------------|
| 自分の勤怠の参照 | `record.user == user` |
| 部下の勤怠の参照 | `record.user.manager == user`（または上長階層を辿る `user.subordinate_of?(record.user)`） |
| 部下の申請の承認 | `manager?` かつ承認ルート上の承認者 かつ `record.user != user`（自己承認防止） |
| マスタ管理 | `hr_admin?` |
| 代理打刻 | `manager?` かつ部下 |

- **`scope`:** 一覧系は `Pundit::Scope` で「自分 + 部下」に絞る（SF の OwnerId ポリシー / ロール階層共有に相当）。
- **自己承認防止:** SF 版が Apex `before update` で行っていた `UserInfo.getUserId() == Requester__c` チェックは、承認サービス内 + ポリシーの二重で担保（API・直接更新でもブロック）。

### 3.5 オーナーシップ（SF の OwnerId ポリシー相当）

SF 版は OWD=Private 下で「当事者が自分のレコードを見られる」ことを `OwnerId` 明示セットで担保していた。Rails では **`user_id`（対象社員の外部キー）+ Pundit スコープ**でこれを表現する。代理打刻・バッチ生成でも `user_id` は必ず対象社員にセットし、操作者は `AttendanceHistory` 側に別途記録する（オーナーと操作者の分離）。

---

## 4. データモデル

### 4.1 命名規約と共通方針

- SF の `__c` サフィックス・API 名は廃止し、Rails の snake_case カラムに翻訳する（例: `ClockIn__c` → `clock_in`、`IsActive__c` → `active`）。
- **全ドメインモデルに `organization_id`**（NOT NULL・FK・複合インデックス先頭）。
- 時刻はすべて `timestamptz`（UTC 保存）。**労働法判定はユーザー組織のタイムゾーン**（`Organization#time_zone`、既定 `Asia/Tokyo`）に変換してから行う（SF 版の `DateUtil.getUserLocalDate()` パターンに相当）。深夜帯判定・日付確定はこの変換が肝。
- 金額は扱わない。時間は分（整数）で中間計算し、最終表示・保存のみ時間単位（`decimal(6,2)`）。
- SF の Formula フィールドは Rails の算出メソッド or Postgres 生成列で表現する。

### 4.2 Organization（テナント・新規）

| カラム | 型 | 説明 |
|--------|-----|------|
| name | string | 企業名 |
| subdomain | string | テナント識別子（ユニーク） |
| time_zone | string | 既定 `Asia/Tokyo`。労働法判定の基準 TZ |
| fiscal_year_end_month | integer | 年度終了月（3 or 12 など。SF: `FiscalYearEndMonth__c`） |
| active | boolean | 契約有効フラグ |

### 4.3 User（社員・新規 / Devise）

| カラム | 型 | 説明 |
|--------|-----|------|
| organization_id | bigint | テナント |
| email | string | ログイン ID（テナント内ユニーク） |
| encrypted_password 等 | — | Devise 標準 |
| name | string | 氏名 |
| employee_code | string | 社員番号（テナント内ユニーク） |
| role | integer (enum) | employee / manager / hr_admin |
| manager_id | bigint | 直属上長（自己参照 FK・null 可） |
| exempt_from_overtime | boolean | 管理監督者（労基法 41 条）。割増・36 協定から除外 |
| birth_date | date | 年少者深夜制限（労基法 61 条）判定用 |
| email_enabled | boolean | 個人メール通知 opt-in（既定 false） |
| active | boolean | 在籍フラグ（退職で false。SF の `User.IsActive` 相当） |

> **退職処理:** `active=false` で論理退職。`UserWorkPattern` を無効化、`LeaveBalance` は退職後 5 年保持、`MonthlyAttendanceSummary` は永久保持（§11.2）。

### 4.4 WorkPattern（勤務パターン）

| カラム | 型 | 説明 |
|--------|-----|------|
| name | string | パターン名（日勤・夜勤・フレックス等） |
| start_time | time | 所定始業時刻 |
| end_time | time | 所定終業時刻 |
| break_minutes | integer | 所定休憩時間（分） |
| standard_work_hours | decimal | 1 日の所定労働時間 |
| night_shift | boolean | 日跨ぎ勤務（true: end_time を翌日換算） |
| flextime | boolean | フレックスタイム制 |
| core_time_start / core_time_end | time | フレックス時のコアタイム |
| morning_half_break_minutes | integer | 午前半休時の休憩（null 時は break_minutes/2） |
| afternoon_half_break_minutes | integer | 午後半休時の休憩（null 時は break_minutes/2） |
| active | boolean | 有効フラグ |

**法定休憩バリデーション（労基法 34 条 1 項）— モデルバリデーションで保存ブロック:**

| 所定労働時間 | 最低休憩 | エラー |
|-------------|---------|--------|
| 6h 超〜8h 以下 | 45 分 | 「6 時間超の勤務には 45 分以上の休憩が必要です（労基法 34 条）」 |
| 8h 超 | 60 分 | 「8 時間超の勤務には 60 分以上の休憩が必要です（労基法 34 条）」 |

半休用の休憩時間にも同様（半休の所定労働は `standard_work_hours / 2` で判定）。

`night_shift && flextime` の同時指定は**保存許可・警告バッジ表示**。優先ルール: 時刻計算は night_shift（翌日換算）、遅刻早退判定は flextime（コアタイム基準）。

### 4.5 LeaveType（休暇種別）

| カラム | 型 | 説明 |
|--------|-----|------|
| name | string | 種別名（有給・慶弔・産休・振替休日・代休等） |
| system_type | integer (enum) | annual / substitute_holiday / compensatory_leave / child_care / paternity_leave / other |
| allow_half_day | boolean | 半日取得可否 |
| paid_leave | boolean | 有給消化対象（残高から減算） |
| description | text | 説明 |
| active | boolean | 有効フラグ |

### 4.6 UserWorkPattern（パターン割当）

| カラム | 型 | 説明 |
|--------|-----|------|
| user_id / work_pattern_id | bigint | 割当先・パターン |
| start_date / end_date | date | 適用期間（end_date null = 無期限） |
| active | boolean | 有効フラグ |

**重複制約:** 同一ユーザーで有効な割当の日付範囲は重複不可（モデルバリデーション。`end_date = null` は全未来日と重複扱い）。打刻時は「打刻日時点で有効な 1 件」を `start_date <= 当日 AND (end_date >= 当日 OR end_date IS NULL) AND active` で取得。

### 4.7 CompanyCalendar（会社カレンダー）

| カラム | 型 | 説明 |
|--------|-----|------|
| date | date | 対象日 |
| day_type | integer (enum) | weekday / saturday / sunday / holiday / company_holiday / legal_holiday |
| name | string | 祝日名・休業理由 |
| fiscal_year | string | 年度 |
| counts_as_paid_leave | boolean | 会社休業日を有給日数に含めるか |

**未登録日のフォールバック:** レコードがない日は ISO 曜日番号（ロケール非依存）で判定（月〜金=weekday、土=saturday、日=sunday）。共通ロジックは `CompanyCalendarResolver`（PORO）に集約。

**法定休日:** 多くは日曜を指定。`legal_holiday` は `sunday` と排他。法定休日労働は 35% 割増対象で**月 60h カウントから除外**。未登録時は法定外休日（25%）に安全側フォールバック。

### 4.8 AttendanceRecord（勤怠記録）— ドメインの中核

| カラム | 型 | 説明 |
|--------|-----|------|
| user_id | bigint | 対象社員 |
| work_date | date | 勤務日（夜勤は出勤日で統一） |
| clock_in / clock_out | timestamptz | 打刻時刻 |
| work_pattern_id | bigint | **打刻時点で確定**したパターン（打刻後の割当変更は当日に影響しない） |
| actual_work_hours | decimal(6,2) | 実労働時間（退勤−出勤−休憩） |
| legal_overtime_hours | decimal(6,2) | 法定残業（実労働−所定。負は 0） |
| scheduled_overtime_hours | decimal(6,2) | 所定外残業（退勤−所定終業。負は 0） |
| deep_night_hours | decimal(6,2) | 深夜労働（22:00–05:00・休憩按分控除後。§5.3） |
| status | integer (enum) | working / clocked_out / morning_half / afternoon_half / on_leave / absent |
| is_late / is_early_leave | boolean | 遅刻・早退フラグ |
| late_minutes / early_leave_minutes | integer | 遅刻・早退分数 |
| is_holiday_work | boolean | 承認済み休日出勤日への打刻で true |
| absence_reason | integer (enum) | 欠勤確定時の理由（§6.10） |
| proxy_clock_reason | integer (enum) | 代理打刻時の理由（§6.1） |
| work_location | integer (enum) | office / telework / business_trip（育介法対応・v2） |
| note | text | 備考（代理打刻・インターバル不足の自動追記先） |
| archived | boolean | アーカイブ済み（§11） |

> **計算列の方針:** `actual_work_hours` 等は**サービスで算出して保存**（打刻・打刻変更承認・休暇承認時に再計算）。理由は CSV 出力・集計クエリでの再計算コストを避け、SF 版と同じ「常時保存」運用にするため。算出は §5 の計算オブジェクトに委譲。

### 4.9 LeaveRequest（休暇申請）

| カラム | 型 | 説明 |
|--------|-----|------|
| requester_id | bigint | 申請者 |
| leave_type_id | bigint | 休暇種別 |
| start_date / end_date | date | 期間 |
| half_day_type | integer (enum) | none / morning / afternoon |
| days_requested | decimal(6,2) | 取得日数（半休 0.5・土日祝除外で算出） |
| reason | text | 申請理由 |
| approval_status | integer (enum) | applying / approved / rejected / canceled / withdrawal_requested / withdrawn |
| withdrawal_reason | text | 撤回理由（撤回申請時必須） |
| last_stale_notified_on | date | 承認滞留アラートの重複防止 |

**半休排他:** `half_day_type != none` のとき `start_date == end_date` 必須。
**取得日数算出:** §5.5 `LeaveDaysCalculator`。

### 4.10 LeaveBalance（休暇残高）

| カラム | 型 | 説明 |
|--------|-----|------|
| user_id / leave_type_id | bigint | 対象 |
| fiscal_year | string | 年度 |
| granted_days | decimal | 当年度新規付与日数 |
| carry_over_days | decimal | 前年度繰越（年度更新ジョブが設定） |
| used_days | decimal | 使用済み（承認時に加算） |
| granted_on | date | 有給付与日（5 日義務の起点） |

- **残日数（算出）:** `granted_days + carry_over_days - used_days`（メソッド or 生成列）
- **取得義務期限（算出）:** `granted_on + 365 日`（5 日取得義務の期限。null safe）
- **同時実行制御:** 承認時は `LeaveBalance` を `lock!`（`FOR UPDATE`）で取得し、`used_days + days_requested > granted_days + carry_over_days` ならエラー（並行承認による残日数マイナス防止）。SF 版の `FOR UPDATE` をそのまま `ActiveRecord#lock!` に翻訳。
- **繰越:** 年度更新時 `min(前年度残日数, organization_setting.carry_over_limit)` を翌年度 `carry_over_days` に設定。

### 4.11 ClockChangeRequest（打刻変更申請）

| カラム | 型 | 説明 |
|--------|-----|------|
| attendance_record_id | bigint | 対象記録（change_type=new_entry 時は null 可） |
| requester_id | bigint | 申請者 |
| change_type | integer (enum) | clock_in / clock_out / both / new_entry |
| target_date | date | new_entry 時必須（既存区分は記録から自動） |
| original_clock_in / original_clock_out | timestamptz | 変更前（競合チェック用） |
| new_clock_in / new_clock_out | timestamptz | 変更後 |
| reason | text | 変更理由（必須） |
| approval_status | integer (enum) | LeaveRequest と同じ 6 値 |
| withdrawal_reason | text | 撤回理由 |
| last_stale_notified_on | date | 滞留アラート重複防止 |

**new_entry:** 欠勤日（status=absent）への打刻追加に使用。全休日（on_leave）への追加は禁止（バリデーション）。半休日の追加は通常の変更申請で対応。
**競合チェック:** 承認時に `original_*` と現在の記録値を照合し、不一致なら承認エラー（§7.4）。

### 4.12 HolidayWorkRequest（休日出勤申請）

| カラム | 型 | 説明 |
|--------|-----|------|
| requester_id | bigint | 申請者 |
| work_date | date | 出勤予定日（カレンダーで平日以外のみ許可） |
| compensation_leave_type_id | bigint | 代償休暇種別（振替休日 or 代休の LeaveType） |
| reason | text | 出勤理由 |
| approval_status | integer (enum) | applying / approved / rejected / canceled |

**承認後の自動処理:** 当日の打刻に `is_holiday_work=true`、`compensation_leave_type` の `LeaveBalance.granted_days` を +1。未打刻のまま過去日になった場合は代休取消フロー（§6.11）。

### 4.13 MonthlyAttendanceSummary（月次サマリ）— 永久保持

| カラム | 型 | 説明 |
|--------|-----|------|
| user_id | bigint | 対象社員 |
| year_month | string | 対象年月（例 `2026-03`） |
| scheduled_work_days | integer | 所定出勤日数（カレンダーから） |
| work_days | integer | 実出勤日数 |
| total_work_hours / total_overtime_hours | decimal | 月合計 |
| overtime_hours_over_60 | decimal | 月 60h 超残業（50% 対象。法定休日は含まない） |
| holiday_work_hours | decimal | 法定休日労働（35% 対象。60h カウント外） |
| total_deep_night_hours | decimal(6,2) | 月間深夜労働 |
| paid_leave_days_used | decimal | 有給使用日数 |
| absent_days / late_days / early_leave_days | integer | 欠勤・遅刻・早退回数 |
| total_leave_hours | decimal | 総休暇時間 |
| interval_violation_count | integer | 勤務間インターバル違反回数 |
| consecutive_work_days_max | integer | 最大連続勤務日数 |
| is_medical_guidance_target | boolean | 月残業 80h 超で自動セット |
| medical_guidance_on | date | 産業医面談実施日 |
| medical_guidance_note | string | 面談結果概要 |
| status | integer (enum) | aggregating / submitted / finalized / deferred |
| deferral_reason | text | 差戻し理由 |
| telework_days | integer | テレワーク日数（v2） |

> **長期参照の基点:** 月次集計・トレンドは必ず本モデルを基点にする（`AttendanceRecord` はアーカイブで消えうるが本モデルは永久保持）。

### 4.14 AttendanceHistory（監査証跡）— 追記専用

勤怠に関わる全イベントを前後値つきで完全記録する追記専用ログ。**作成後は readonly**（`before_update`/`before_destroy` で `raise ActiveRecord::ReadOnlyRecord`、または `readonly?` をオーバーライド）。

| カラム | 型 | 説明 |
|--------|-----|------|
| user_id | bigint | 対象社員 |
| event_date | date | 対象勤務日 |
| event_type | integer (enum) | clock_in / clock_out / leave_approved / leave_withdrawn / clock_change_approved / absence_confirmed / absence_to_paid / proxy_clock / interval_shortage |
| source_type / source_id | string / bigint | 起因レコード（polymorphic: LeaveRequest 等） |
| previous_status / new_status | integer | 前後の AttendanceRecord.status |
| previous_clock_in / new_clock_in | timestamptz | 前後の出勤時刻 |
| previous_clock_out / new_clock_out | timestamptz | 前後の退勤時刻 |
| previous_is_late / new_is_late | boolean | 前後の遅刻フラグ |
| previous_late_minutes / new_late_minutes | integer | 前後の遅刻分数 |
| previous_is_early_leave / new_is_early_leave | boolean | 前後の早退フラグ |
| previous_early_leave_minutes / new_early_leave_minutes | integer | 前後の早退分数 |
| note | text | 操作者情報・撤回理由等 |

> **設計意図:** SF の Field History Tracking（18 ヶ月で自動削除）の上位互換。撤回時の状態復元はこのログを参照する（§7.6）。5 年保持。

### 4.15 OrganizationSetting（組織設定）— SF の AttendanceSettings__mdt 相当

テナントごとに 1 行。SF の Custom Metadata Type を**型付きの設定テーブル**へ翻訳（key-value ではなくバリデーション可能なカラムとする）。管理者が管理画面から編集。

| カラム | 型 | 既定 | 説明 |
|--------|-----|------|------|
| closing_day | integer | 31 | 締め日（31=月末） |
| submit_deadline_days | integer | 5 | 翌月の提出期限 |
| overtime_calc_base | integer (enum) | legal | 表示・集計の残業基準（legal / scheduled） |
| overtime_alert_threshold1/2/3 | integer | 45/80/100 | 残業アラート閾値 |
| carry_over_limit | integer | 20 | 有給繰越上限 |
| daily_batch_hour | integer | 2 | 日次バッチ実行時 |
| fiscal_year_end_month | integer | 3 | 年度終了月 |
| leave_expiry_reminder_days | integer[] | [30,14] | 失効前リマインド（日前。配列で多段化） |
| quiet_hours_enabled | boolean | true | 通知抑制 ON/OFF |
| quiet_hours_start / quiet_hours_end | integer | 19 / 8 | 抑制時間帯 |
| holiday_block_enabled | boolean | true | 土日祝の通知ブロック |
| rest_interval_hours | integer | 11 | 勤務間インターバル閾値 |
| consecutive_work_day_limit | integer | 13 | 連続勤務アラート閾値 |
| email_notification_enabled | boolean | false | 組織メール通知（二重 opt-in の組織側） |
| annual_overtime_limit | integer | 360 | 36 協定・年間上限（通常） |
| annual_overtime_special_limit | integer | 720 | 年間上限（特別条項・違法ライン） |
| multi_month_average_limit | integer | 80 | 2–6 ヶ月平均上限 |
| monthly_over45h_limit_count | integer | 6 | 月 45h 超の年間許容回数 |
| stale_approval_days | integer | null | 承認滞留アラート日数 |

### 4.16 ReasonTemplate（申請理由テンプレート）

| カラム | 型 | 説明 |
|--------|-----|------|
| label | string | 管理用識別名 |
| template_text | string | 挿入テキスト |
| applies_to | integer (enum) | clock_change / leave / both |
| active | boolean | 有効フラグ |

### 4.17 UserNotificationPreference（ユーザー通知設定）

1 ユーザー 1 行（なければ OrganizationSetting にフォールバック）。

| カラム | 型 | 説明 |
|--------|-----|------|
| user_id | bigint | 対象（ユニーク） |
| quiet_hours_enabled | boolean | 個人の抑制 ON/OFF |
| quiet_hours_start / quiet_hours_end | integer | 個人の抑制時間帯 |
| holiday_block_enabled | boolean | 個人の休日ブロック |
| email_enabled | boolean | 個人メール opt-in（組織側が true のときのみ有効・二重 opt-in） |

### 4.18 Notification / NotificationDelivery（通知）— SF の NotificationQueue + Custom Notification 相当

SF の「Custom Notification（10 件/txn 上限）+ NotificationQueue__c」を、Rails では「**ベル通知（永続 + Turbo Streams）+ 配信ジョブ**」へ翻訳。10 件/txn のような上限はない。

**Notification（ベル通知の実体）:**

| カラム | 型 | 説明 |
|--------|-----|------|
| target_user_id | bigint | 通知先 |
| title / body | string / text | 内容 |
| priority | integer (enum) | action_required / informational / reference |
| source_type | integer (enum) | clock_out_forgotten / leave_expiry / overtime_alert 等 |
| subject_user_id | bigint | 通知対象者（重複制御キー） |
| read_at | timestamptz | 既読時刻 |

**NotificationDelivery（抑制キュー + メール配信状態）:**

| カラム | 型 | 説明 |
|--------|-----|------|
| notification_id | bigint | 親通知 |
| channel | integer (enum) | in_app / email |
| scheduled_at | timestamptz | 抑制終了後の送信予定時刻 |
| status | integer (enum) | pending / sent / error |
| retry_count | integer | 失敗リトライ（>3 で error 確定） |

> オフタイム抑制は enqueue 時に `scheduled_at` を計算し、Active Job の `set(wait_until:)` で後送する（§9.3）。

### 4.19 Todo（社員 TODO）

| カラム | 型 | 説明 |
|--------|-----|------|
| user_id | bigint | 所有者 |
| subject | string | タイトル |
| due_on | date | 期日 |
| completed | boolean | 完了フラグ |
| parent_id | bigint | 親タスク（自己参照・サブタスク） |

### 4.20 IntegrationEvent（連携イベント・Outbox）— SF の Platform Event 相当

Gatcha Work 連携用の `LeaveApproved__e` / `LeaveRevoked__e` を、Rails では **Outbox パターン**（イベントテーブル + 配信）で表現する。詳細は §14。

| カラム | 型 | 説明 |
|--------|-----|------|
| event_type | string | `leave_approved` / `leave_revoked` |
| payload | jsonb | user_id, entry_date, hours, leave_type_name, leave_type_id 等 |
| published_at | timestamptz | 配信済み時刻（null=未配信） |

---

## 5. 労働時間計算エンジン（純粋計算オブジェクト）

> SF 版では Apex トリガー内に埋もれ検証困難だった計算群を、AR 非依存の PORO に切り出す。入力は値、出力は値。DB なしで網羅的に単体テストする。各計算は**分単位（整数）で中間計算し、最終値のみ時間単位（`decimal(6,2)`）へ HALF_UP 変換**する（丸めルール統一）。すべての時刻比較は**組織 TZ へ変換後**に行う。

### 5.1 WorkTimeCalculator（実労働時間）

```
実労働時間 = 退勤時刻 − 出勤時刻 − 休憩時間
```

- 半休日の所定労働時間は `standard_work_hours / 2`
- 半休日の休憩: 午前半休は `morning_half_break_minutes`（null 時 `break_minutes/2`）、午後半休は `afternoon_half_break_minutes`（null 時 `break_minutes/2`）
- **夜勤（night_shift）:** `start_time > end_time` のとき `end_time` を翌日換算（+24h）。`work_date` は出勤日で統一

### 5.2 OvertimeCalculator（残業）

二系統を**常時**算出して保存:

```
法定残業 (legal_overtime_hours)     = max(0, 実労働時間 − 所定労働時間)
所定外残業 (scheduled_overtime_hours) = max(0, 退勤時刻 − 所定終業時刻)
```

- 表示・集計には `organization_setting.overtime_calc_base`（legal / scheduled）で使う値を切替（両方常時保存ゆえ過去再計算不要）
- 月次の 60h 超・管理監督者除外・36 協定は §8 で集約

### 5.3 DeepNightCalculator（深夜労働 22:00–05:00 / 労基法 37 条 4 項）

**深夜帯定義:** `22:00:00` 〜翌 `05:00:00`。**22:00:00 ちょうどの退勤は含まない**（開始点）。22:00:01 以降は含む。05:00:00 で終了。

```
Step 1: 勤務帯 [clock_in, clock_out] と深夜帯 [22:00, 翌05:00] の重複（overlap_minutes）を算出
        夜勤も出勤日の 22:00〜翌05:00 との overlap で算出
Step 2: 休憩の按分控除
          deep_night_ratio = overlap_minutes / total_work_minutes
          deep_night_break  = FLOOR(break_minutes × deep_night_ratio)  # 切り捨て=労働者有利
Step 3: deep_night_hours = round((overlap_minutes − deep_night_break) / 60, 2, HALF_UP)
```

実装は `BigDecimal#round(2, half: :up)`。フレックス・変形労働でも**ロジック同一**（深夜割増は免除されない）。

### 5.4 LateEarlyCalculator（遅刻・早退判定）

**固定時間制（flextime=false）:**

- 遅刻: `clock_in > start_time` → `is_late=true`, `late_minutes` 算出
- 早退: `clock_out < end_time` → `is_early_leave=true`, `early_leave_minutes` 算出

**フレックス（flextime=true）:**

| 項目 | 判定 |
|------|------|
| 遅刻 | コアタイム開始前に出勤しているか（在席なら false） |
| 早退 | コアタイム終了前に退勤していないか（在席なら false） |
| 分数 | `late_minutes` / `early_leave_minutes` は **0 固定**（二値管理） |

**半休日（共通）:** 午前半休は終業側のみ判定（遅刻免除）、午後半休は始業側のみ判定（早退免除）。
**パターン未割当:** 判定スキップ + 管理者へ通知。

### 5.5 LeaveDaysCalculator（取得日数）

```
start_date〜end_date の全日から除外:
  - 土曜・日曜
  - day_type = holiday
  - day_type = company_holiday かつ counts_as_paid_leave = false
残日数を合計（半休は 0.5）
```

申請フォームで Stimulus によりリアルタイム計算・表示（提出前に取得日数を確認）。

### 5.6 割増率の複合ルール（加算方式・参考）

計算エンジンは時間数を算出し、割増率の適用は給与システムの責務。ただし区分は CSV で提供:

| 区分 | 合計割増率 |
|------|----------|
| 法定残業（60h 以下） | 25% |
| 法定残業（60h 超） | **50%** |
| 法定休日労働 | 35% |
| 深夜のみ（所定内） | 25% |
| 法定残業 + 深夜 | 50% |
| 60h 超 + 深夜 | 75% |
| 法定休日 + 深夜 | 60% |

> 法定休日労働は 60h カウント外ゆえ「法定休日 + 深夜 + 60h 超」の三重複合は発生しない（上限 60%）。

---

## 6. 機能仕様

### 6.1 出退勤打刻

- Hotwire の「出勤 / 退勤」ボタン（Turbo + Stimulus）。モバイルは大きめ UI・PWA
- 打刻時に現在時刻を記録し `AttendanceRecord` を作成 / 更新
- **パターン確定:** 出勤打刻時に `UserWorkPattern` から有効な勤務パターンを引き、`attendance_record.work_pattern_id` に**スナップショット**。以後の割当変更は当日に影響しない（翌営業日から適用）
- **二重打刻防止:** 同日出勤済みなら出勤ボタンを Turbo で disable + 「すでに出勤済みです」。サーバー側でもバリデーション（モバイルのタップ遅延対策）
- **代理打刻（管理者）:** 対象社員を選び打刻。承認不要（権限行使として即時）。理由（`proxy_clock_reason`）選択必須
  - `note` に「代理打刻（出勤/退勤）：{操作者名} が {日時} に実施（理由: {reason}）」を自動追記（既存は `；` 連結）
  - `AttendanceHistory`（event_type: proxy_clock）に記録
  - 対象社員へ即時通知:「{管理者名} が代理で{出勤/退勤}打刻を実行しました。時刻が異なる場合は打刻変更申請を提出してください」

**proxy_clock_reason（enum）:** system_failure / unreachable / forgot_punch / other（「その他」でも自由入力欄は出さない＝§6.10 欠勤確定とは非対称）

### 6.2 休暇申請

- 社員が休暇種別を選び申請。半休可能種別で午前/午後半休を選択（半休は 1 日のみ）
- v1 は日単位・半日単位のみ（時間単位は v3）
- 複数日申請可（`days_requested` は §5.5 でリアルタイム算出）
- **残高 2 段階表示**（paid_leave 種別のみ）: 確定残高（承認済）と仮残高（申請中含む）。申請後残日数が **正→通常 / 0→アンバー + ℹ️「今年度の有給を使い切ります」/ 負→赤警告**。不足でも申請は通す（承認者が最終判断）
- 理由欄に `ReasonTemplate`（applies_to: leave / both）をチップ表示
- **承認後の自動処理**（承認サービス、§7）: 対象日の `AttendanceRecord` 作成/更新（全休→on_leave、午前→morning_half、午後→afternoon_half）、打刻済なら遅刻早退フラグ再計算・上書き（午前半休→遅刻免除 / 午後半休→早退免除）、`LeaveBalance.used_days` 加算（`lock!`）、`AttendanceHistory`（leave_approved）記録、`IntegrationEvent`（leave_approved）publish
- **却下/取消:** `IntegrationEvent`（leave_revoked）publish
- **欠勤後の事後有給:** 承認時に status を absent→on_leave へ上書き、`AttendanceHistory`（absence_to_paid）記録
- **月跨ぎ申請:** 1 件で申請・承認。集計は各日付の属する月に分割計上。締め済み月の日付が含まれる場合は**その月の日付のみブロック**し差戻しを促す（他月は正常進行）
- **年度跨ぎ申請:** `LeaveBalance` 加算は `start_date` の属する年度に統一（日割り分割しない）
- 締め済み月への申請は §6.7 の制限に従う

> **Rails での簡素化:** SF 版は「複数日承認で 60 DML 超」を避けるため同期/非同期を分離していた。Rails ではガバナ制限がないため、承認サービスを 1 トランザクションで実行できる（大量日数時のみ `insert_all` でバルク化を選択）。`IntegrationEvent` の publish は after_commit で 1 回だけ。

### 6.3 打刻時刻変更依頼

- 既存記録への出勤/退勤時刻変更（change_type: clock_in / clock_out / both）、欠勤日への新規打刻（new_entry）
- 理由必須・テンプレートチップ表示
- **承認時:** 競合チェック（§7.4）→ `AttendanceRecord` 時刻更新（or 新規）→ 実労働/残業/遅刻早退の再計算（§5）→ `AttendanceHistory`（clock_change_approved）記録
- 撤回時は履歴参照で復元（§7.6）

### 6.4 月次勤怠レポート

- 月単位のサマリ + 日別明細を Hotwire で表示（ViewComponent）
- **CSV エクスポート 2 種**（UTF-8 BOM 付・CRLF・RFC 4180・`YYYY-MM-DD` / `HH:MM` / 小数点ドット）:
  - **月次サマリ CSV:** 所定/実出勤日数・総労働/総残業・60h 超・法定休日・深夜・管理監督者フラグ・有給使用・遅刻早退・総休暇時間
  - **日別明細 CSV:** 日付・出退勤・実労働・残業・深夜・遅刻早退・status（1 行=1 日）
  - 割増区分別（法定残業/60h 超/法定休日/深夜）を網羅し給与システム入力に不足なし
  - **CSV ≠ 賃金台帳:** 本 CSV は勤務実績データ。賃金台帳（基本給・手当・控除）は給与システムの責務
- **集計タイミング 2 種:**
  - **日次バッチ（前日分積み上げ）:** `daily_batch_hour` 時に前日分加算（月中は概算）
  - **提出時全件再集計:** 「提出」時に対象月を正確に再集計し確定値保存。対象月の `AttendanceRecord` を 1 クエリで取得し `MonthlySummaryService` で計算（SF の「ループ内 SOQL 禁止」は Rails では自然な書き方で達成）
- 提出前に退勤未入力日があれば警告（提出は可能）

### 6.5 残業時間自動計算

§5.2（算出）+ §8（月次の 60h 超・管理監督者・36 協定）に集約。退勤打刻・打刻変更承認・休暇承認時に再計算。

### 6.6 勤怠締めフロー（月次サマリ状態機械）

AASM で `MonthlyAttendanceSummary.status` を管理:

| 状態 | 社員操作 | 遷移 |
|------|---------|------|
| aggregating（集計中） | 打刻・申請すべて自由 | 提出 → submitted |
| submitted（提出済） | 打刻変更/休暇/撤回申請の**新規作成を制限** | 確定 → finalized / 差戻し → deferred |
| finalized（確定） | 全ロック | 差戻し → deferred |
| deferred（差戻し） | 制限解除・再度操作可 | 再提出 → submitted |

- **状態遷移はカスタム実装**（SF の標準 Reject は「却下・終了」で差戻し→修正→再提出に不適合という事情は Rails でも同じ。AASM で素直に表現）
- **差戻し:** `deferral_reason` 必須・社員へ通知・「集計中」には戻さない
- **承認時の締めステータス再チェック:** 申請作成後に締めが submitted/finalized へ遷移した場合、承認操作時に再検証しロック中なら承認エラー（CCR / LR / HWR の全 3 種。§7）
- **提出前チェック:** 承認進行中（プロセス起動済み未完了）の申請があれば提出ボタン非活性 + 対象一覧表示。申請中（未起動）はキャンセルで提出可
- 編集制御はサーバー側バリデーション + UI（Turbo で disable）の二重
- **月次一括確定:** 複数社員分は SolidQueue ジョブで分割（Rails では DML 制限はないが、応答性のためバックグラウンド化）

### 6.7 締めステータスによる申請制限（横断ルール）

submitted / finalized の月に属する日付に対する CCR / LR / HWR の**新規作成・撤回申請を制限**。修正は「管理者へ差戻し依頼 → deferred で操作 → 再提出」の通常フローに統一。実装は各申請モデルのバリデーション（対象日の月次サマリ status を参照）。

### 6.8 打刻漏れ検知（日次バッチ）

SolidQueue 定期ジョブ（毎日 `daily_batch_hour` 時）で前日分を検査:

**退勤打刻忘れ:**
```
(status ∈ {working, morning_half, afternoon_half}) AND clock_in IS NOT NULL AND clock_out IS NULL
```
`clock_in IS NOT NULL` で「休暇承認のみ・打刻なし」の誤検知を防ぐ。**夜勤者**（有効な `UserWorkPattern` の `work_pattern.night_shift=true`）はバッチ時点で勤務中の可能性があり対象外（翌日実行で検出）。回復は打刻変更申請（推奨）or 代理打刻。通知に「退勤時刻を申請する」リンク（1 タップで申請画面へ）。

**無打刻検知（2 カテゴリ・通知のみ。AttendanceRecord は作らない）:**

| カテゴリ | 条件 | 通知 |
|---------|------|------|
| 欠勤候補 | AttendanceRecord も LeaveRequest（全 status）も無 | 管理者 + **本人**へ通知 |
| 休暇申請中・打刻なし | AR 無・LeaveRequest（申請中/進行中）有 | 管理者へ通知 |

毎日実行（土日祝含む）。通知は**本人の次の稼働日**に送信。欠勤候補は本人へ事前通知:「{日付} の出勤記録がありません。打刻漏れなら打刻変更申請を（猶予: 翌営業日 17:00）」。猶予内に申請なければ管理者の「欠勤確定待ち」に表示。

### 6.9 勤務間インターバルチェック（§8.4 と連動）

出勤打刻時にリアルタイム判定。前日退勤と当日出勤の間隔が `rest_interval_hours`（既定 11）未満なら本人へ画面警告・管理者へ通知。`AttendanceRecord.note` に自動追記 + `interval_violation_count` インクリメント + `AttendanceHistory`（interval_shortage）記録。打刻はブロックしない。夜勤は翌々日の出勤で判定。

### 6.10 欠勤確定フロー

1. 日次バッチが欠勤候補を検知 → 管理者 + 本人へ通知
2. 猶予（翌営業日 17:00）経過後、管理者がダッシュボードの「欠勤候補一覧」を確認
3. 管理者が対象社員 × **1 件以上の日付**を選び、**欠勤理由**を入力して「欠勤確定」（1 操作 = 1 社員 × N 日付の一括確定）
4. `AttendanceRecord`（status: absent）を一括作成・`absence_reason` 記録、`AttendanceHistory`（absence_confirmed）を N 件記録
5. 対象社員へ通知（1 社員 × N 日付を 1 件に集約。複数日は「{日付列}（計 N 日）の欠勤が確定されました。事後の有給申請が可能です」）

**absence_reason（enum）:** unauthorized（無届）/ illness（疾病・傷病）/ family（家庭事情）/ investigating（打刻漏れ調査中）/ other。**other 選択時のみ** `note` 入力欄を表示（任意・空可）。other 以外は note=null。

**制限:** finalized 月への欠勤確定禁止（差戻し → 欠勤確定 → 再提出）。deferred 月は許可。

### 6.11 休日出勤フロー

1. 社員が `HolidayWorkRequest` を申請（出勤予定日・代償休暇種別・理由）。`work_date` はカレンダーで平日以外のみ（バリデーション）・同一日重複禁止
2. 承認（§7）後、当日打刻で `is_holiday_work=true` 自動セット
3. 承認時に `compensation_leave_type` の `LeaveBalance.granted_days` を +1
4. 社員は後日 LeaveRequest（振替休日 or 代休）で取得

**振替休日と代休の法的区別**（CSV 区分・給与影響）:

| | 振替休日 | 代休 |
|--|---------|------|
| 定義 | 事前に法定休日を別日へ振替 | 法定休日出勤後に別日を休暇 |
| 割増 | 同一週内なら割増不要 | 35% 割増は**消滅しない** |

**HWR 承認後に未打刻の場合:** 月次バッチで「承認済 × work_date 過去 × 当日 AR なし」を検出 → 管理者へ通知・「休日出勤未打刻」一覧表示 → 管理者が ①代休取消（`granted_days` −1 + 通知）②打刻追加（代理打刻）③保留 を選択。**月次確定前に必ず解消**（割増未記録なのに代休付与の不整合を防ぐ）。

---

## 7. 承認エンジン（自作 / SF 標準承認プロセスの代替）

> SF 版は標準 Approval Process（2GP 非対応で導入先が手動作成）を使っていた。Rails には標準機構がないため**自作**するが、その分テナント別に柔軟・透明な承認フローを構築できる。

### 7.1 構成モデル（追加）

| モデル | 役割 |
|--------|------|
| **ApprovalRoute** | テナント別承認ルート。`applies_to`（leave / clock_change / holiday_work）× `target`（general_employee / manager）で SF の「プロセス A / B」を表現 |
| **ApprovalRouteStep** | ルート内の段（position）+ 承認者解決方式（`approver_type`: manager / department_head / specific_user / role）+ specific_user_id |
| **ApprovalAssignment** | 実行時。approvable（polymorphic）× step × approver × decision（pending/approved/rejected）× acted_at × comment |

`approval_status`（申請モデル側）は AASM で**業務ステータス**（applying / approved / rejected / canceled / withdrawal_requested / withdrawn）のみ保持。**段階情報**（第 1 段階待ち / 第 2 段階待ち）は `ApprovalAssignment` 群から導出して表示（SF の `ProcessInstance` 参照に相当）。

### 7.2 承認ルート解決

| プロセス | 対象 | ルート |
|---------|------|--------|
| 一般社員用（target: general_employee） | `role: employee` | 第 1 段階: 直属上長（manager）→ 第 2 段階: 部門長 |
| 管理職用（target: manager） | `role: manager` | 第 1 段階: 部門長 → 第 2 段階: 人事 |

- 承認者解決は `manager_id` 階層を基本（第 2 段階は第 1 段階承認者の manager から解決）。階層が未整備なら `specific_user` 指定にフォールバック（SF の「ロール非依存モード」相当だが、Rails では `manager_id` で素直に表現）
- ルート選択は申請者の `role`（排他）で決定。SF の「Entry Criteria 排他設計（二重マッチング防止）」は Rails では条件分岐で自然に排他

### 7.3 自己承認防止

承認サービス（`ApprovalService#approve`）の冒頭 + Pundit ポリシーの二重で `approver != approvable.requester` を検証。API・直接更新でもブロック。

### 7.4 競合チェック（打刻変更）

CCR 承認時、`original_clock_in/out` と現在の `AttendanceRecord` 値を照合。不一致なら承認エラー + 承認者へ通知（「変更前時刻が現在の記録と一致しません」）。承認者は却下 or 申請者へ再申請を促す。

### 7.5 代理承認・滞留アラート

- **代理承認:** 承認者は自身の代理承認者を設定可能（`User` に `delegate_approver_id`、or 承認画面で委任）。承認者不在時に代理が承認できる
- **滞留アラート:** 承認待ちが `stale_approval_days` 超過で週次バッチが管理者の上長（manager の manager）へ通知。`last_stale_notified_on` で重複防止

### 7.6 撤回フロー（承認済の取消）

承認待ち中の取り下げ（取消 / canceled）とは別の、**承認済レコードの撤回**フロー:

| 操作 | 処理 |
|------|------|
| 撤回申請（申請者） | `withdrawal_reason` 必須 → status: withdrawal_requested → 管理者へ通知。AASM ガードで承認エンジンの再起動を防止 |
| 撤回承認（管理者） | status: withdrawn → 復元処理（下記） |
| 撤回却下（管理者） | status: approved に戻す → 申請者へ却下理由通知 |

**LeaveRequest 撤回の復元処理:** `AttendanceHistory` を参照し対象日の `AttendanceRecord` を申請前状態へ復元、`LeaveBalance.used_days` 減算、`IntegrationEvent`（leave_revoked）publish、`AttendanceHistory`（leave_withdrawn）記録。
**ClockChangeRequest 撤回の復元処理:** 履歴参照で打刻時刻を復元、各種再計算、`AttendanceHistory` 記録。
**制限:** submitted / finalized 月への撤回申請は §6.7 に従い制限。

### 7.7 申請の初期ステータス

`before_create` で `approval_status = applying` をセット（AASM 初期状態）。承認エンジンの起動はその後。

---

## 8. コンプライアンス監視（労務違反の予防装置）

> 月次・退勤時の各チェックは `ComplianceService` 群（PORO + サービス）に集約。**打刻のブロックは一切行わない**（労基法上、実労働時間の正確な記録義務がある。ブロックはサービス残業の温床となり法的リスクを増大させる）。違反は事後の管理者通知・人事エスカレーションで対応。

### 8.1 月 60 時間超残業（割増 50% / 2023 年 4 月〜全企業）

- **60h カウント対象:** `legal_overtime_hours` の月間累計。ただし**法定休日労働は除外**
- `overtime_hours_over_60 = max(0, 60h カウント対象 − 60)`
- 法定休日労働は `holiday_work_hours` として別集計（35% 対象・60h カウント外）
- 退勤打刻時に当月累積を計算し 60h 接近でアラート

### 8.2 36 協定の上限管理（労基法 36 条）

**法定上限:**

| 区分 | 上限 | 違反時 |
|------|------|--------|
| 通常 | 月 45h / 年 360h | 是正勧告 |
| 特別条項 | 月 100h 未満 / 年 720h / 2–6 ヶ月平均 80h 以下 | **罰則あり**（懲役 6 月以下 or 罰金 30 万円以下） |
| 特別条項の回数 | 月 45h 超は年 6 回まで | 同上 |

**チェックロジック（月次バッチ + 退勤時即時）:**

```
月次（締め提出・確定時にも再検証）:
  yearly_total   = Σ total_overtime_hours WHERE fiscal_year = 当年度
  months_over_45 = COUNT WHERE total_overtime_hours > 45 AND fiscal_year = 当年度
  a. yearly_total > annual_overtime_limit(360)         → 管理者アラート
  b. yearly_total > annual_overtime_special_limit(720) → 管理者+人事エスカレーション（違法状態）
  c. months_over_45 > monthly_over45h_limit_count(6)   → 管理者アラート

複数月平均（月次バッチ）:
  for n in 2..6: avg = 直近 n ヶ月平均(total_overtime_hours)
    if avg > multi_month_average_limit(80) → 管理者+人事エスカレーション

退勤時即時（既存 3 段階 45/80/100 に追加）:
  当月累積 + 本日見込み > 100h → 警告（打刻ブロックしない）
```

**是正アクション支援:** 管理ダッシュボード「36 協定管理」タブに、月 45h 超→特別条項発動確認、月 80h→産業医面談勧奨、月 100h 接近→人事エスカレーション、年 720h 超→緊急エスカレーション、のチェックリストを表示。

### 8.3 管理監督者の適用除外（労基法 41 条 2 号）

`User.exempt_from_overtime = true` の社員は時間外・休日労働の規定が**適用除外**。ただし**深夜割増（37 条 4 項）は適用除外されない**（最高裁 H21.12.18 ことぶき事件）。

| 区分 | 一般社員 | 管理監督者 |
|------|---------|-----------|
| 法定/所定外残業の**記録** | する | する（客観的把握義務・労安法 66 条の 8 の 3） |
| 残業割増の**対象** | ○ | **×（除外）** |
| 深夜割増（22:00–05:00） | 25% 加算 | **25% 加算（除外されない）** |
| 月 60h 超 50% / 法定休日 35% | ○ | **×（除外）** |
| 36 協定チェック | 対象 | **対象外（集計から除外）** |
| 産業医面談（80h 超） | 対象 | **対象（全労働者）** |

実装: `deep_night_hours` 等は全社員に記録。36 協定チェック・60h・法定休日割増は `exempt_from_overtime` で分岐。CSV に管理監督者フラグ列を含め給与側で分岐可能に。

### 8.4 勤務間インターバル（現行努力義務 → 2027–2028 法的義務化見込み）

§6.9 で判定・記録。`MonthlyAttendanceSummary.interval_violation_count` に月内回数を集計。法改正施行時に `organization_setting` へ enforcement mode（warning / error / block）を追加し段階強化可能とする。

### 8.5 連続勤務日数（現行 4 週 4 休 → 2027–2028 で 13 日上限見込み）

日次バッチで前日までの連続勤務日数を算出（`AttendanceRecord` の status≠on_leave が連続する日数。カレンダー休日に打刻なし→リセット、休日出勤→カウント）。`consecutive_work_day_limit − 2`（既定 11）で管理者へ事前警告、閾値到達で管理者 + 本人へアラート。`MonthlyAttendanceSummary.consecutive_work_days_max` に記録・`AttendanceRecord.note` に注記。打刻はブロックしない。

### 8.6 年次有給休暇 5 日取得義務（労基法 39 条 7 項）

年 10 日以上付与の労働者は付与日から 1 年以内に 5 日以上取得が義務。**違反は 1 人 30 万円以下の罰金**。

```
対象 = LeaveBalance WHERE leave_type.paid_leave AND leave_type.system_type = annual
                      AND (granted_days + carry_over_days) >= 10
取得義務残日数 = max(0, 5 − used_days)
取得期限       = granted_on + 365 日
```

- 「10 日以上」は安全側で `granted_days + carry_over_days >= 10`（繰越含む合算。厚労省 Q&A 2019 準拠）。組織設定で新規付与のみ判定へ切替可
- **段階通知:** 6 ヶ月前（情報）→ 3 ヶ月前（警告）→ 1 ヶ月前（緊急）→ 期限超過（違反通知・管理者 + 人事へ「労基法 39 条 7 項違反（罰金 30 万円/人）」）
- `granted_on` 必須バリデーション（paid_leave かつ annual）。ダッシュボードに「granted_on 未設定の有給残高」警告
- 週次バッチで期限までの残日数に応じ通知。ダッシュボードに対象者・現取得日数・義務残日数・期限を表示（30 日以内を赤・期限超過は別セクション「法定義務違反」バッジ）

### 8.7 産業医面談の記録（労働安全衛生法 66 条の 8）

月 80h 超の時間外労働者に面談機会の提供義務。労基署調査時の「機会提供の証拠」として記録する。新規モデルは作らず `MonthlyAttendanceSummary` に集約:

- `is_medical_guidance_target`: 再集計時に `total_overtime_hours > 80` で自動セット（管理監督者含む全労働者）
- `medical_guidance_on` / `medical_guidance_note`: 管理者が面談後に記録
- ダッシュボード「産業医面談」セクション（対象者・実施日・未実施）。未実施対象者がいれば月次バッチでリマインド

### 8.8 年少者・妊産婦の深夜制限（v2 / 労基法 61 条・66 条 3 項）

- 18 歳未満（`User.birth_date` から判定）: 深夜打刻をブロック（例外フラグ `allow_minor_night_work` で管理者解除可）
- 妊産婦が請求した場合（`night_work_exemption_requested`）: 深夜打刻時に管理者へ警告（ブロックはしない）

---

## 9. 通知設計

通知は **ベル通知（Notification + Turbo Streams で即時表示）** と **メール（Action Mailer）** の 2 チャネル。SF の「Custom Notification 10 件/txn 上限」「Platform Event 二重 publish 回避」は Rails では存在しない。

### 9.1 社員向け通知

| イベント | 優先度 | 手段 | タイミング |
|---------|--------|------|-----------|
| 月次提出期限 | 必須対応 | ベル + メール | 期限 3 日前・1 日前 |
| 月次差戻し | 必須対応 | ベル + メール | 即時 |
| 過重労働 100h 超（本人通知義務） | 必須対応 | ベル + メール | 即時（退勤時） |
| 申請の承認/却下 | 情報提供 | ベル | 即時 |
| 有給失効前 | 情報提供 | ベル + メール（opt-in） | 年度末 N 日前バッチ |
| 振替休日リマインダ | 情報提供 | ベル + メール（opt-in） | 月次バッチ |
| 退勤打刻忘れ | 参考 | ベル | 翌営業日バッチ |

### 9.2 管理者向け通知

| イベント | 優先度 | 手段 | タイミング |
|---------|--------|------|-----------|
| 過重労働 100h 超（管理監督者含む全員） | 必須対応 | ベル + メール | 即時 |
| 過剰残業 80h 超（面接指導義務） | 必須対応 | ベル + メール | 即時 |
| 有給 5 日未取得 | 必須対応 | ベル + メール | 月次バッチ（違反リスク） |
| 承認待ち | 情報提供 | ベル | 即時 |
| 部下の打刻漏れ | 情報提供 | ベル + メール（opt-in） | 翌営業日バッチ |
| 月次未提出者 | 情報提供 | ベル + メール（opt-in） | 期限翌日バッチ |
| 過剰残業 45h 超 | 参考 | ベル | 週次バッチ |

### 9.3 通知抑制モード（オフタイム）

送信前に対象ユーザー設定を参照（`UserNotificationPreference` → なければ `OrganizationSetting`）。抑制時間帯（`quiet_hours_start`〜`quiet_hours_end`）or `holiday_block_enabled` かつカレンダー休日に該当する通知は **`scheduled_at` を抑制終了後に計算し、`NotificationDelivery` をキューイング**。Active Job の `set(wait_until: scheduled_at).perform_later` で後送する（SF の NotificationQueue バッチ処理を ActiveJob の遅延実行へ翻訳）。

### 9.4 優先度と二重 opt-in

| 優先度 | ベル | メール |
|--------|:---:|:---:|
| 必須対応 | ✓ | 常時 |
| 情報提供 | ✓ | 二重 opt-in 時のみ |
| 参考 | ✓ | ― |

二重 opt-in: 組織 `email_notification_enabled` かつ個人 `email_enabled` が両方 true のときのみメール送信。

### 9.5 失敗ハンドリング

`NotificationDelivery.retry_count` で管理。Active Job の `retry_on` + 配信記録で、失敗時 `retry_count` +1・翌バッチ時刻へ再スケジュール。`retry_count > 3` で `status: error` 確定・送信停止。error が閾値（例 10 件）超で hr_admin へ通知。

---

## 10. バックグラウンドジョブ（SolidQueue）

SF の Scheduled Apex / Queueable / Batch Apex を Active Job + SolidQueue へ翻訳。定期ジョブは `config/recurring.yml`（Fugit 構文）。

```yaml
# config/recurring.yml
production:
  daily_attendance_batch:        # 前日積み上げ・退勤漏れ・無打刻/欠勤候補・通知配信
    class: DailyAttendanceJob
    schedule: "at 2am every day"
  notification_dispatch:         # 抑制解除分の配信
    class: NotificationDispatchJob
    schedule: every hour
  weekly_attendance_batch:       # 残業アラート(45h)・滞留・有給5日・各種リマインダ
    class: WeeklyAttendanceJob
    schedule: "at 3am on monday"
  monthly_compliance_batch:      # 36協定(年/複数月平均)・HWR未打刻・繰越・アーカイブ
    class: MonthlyComplianceJob
    schedule: "at 4am on day-of-month 1"
```

> **Rails での簡素化:** SF は「Batch 同時 5 件」「InstallHandler で初回スケジュール」「Custom Notification チェーン」等の制約に縛られていた。SolidQueue は DB ベースで同時実行数を `config/queue.yml` で自由設定でき、recurring.yml が宣言的スケジューラを兼ねる。大量処理は `find_each` / `insert_all` で素直に書ける。

| SF 機構 | Rails 置換 |
|---------|-----------|
| Scheduled Apex（日次/週次） | SolidQueue recurring task |
| Queueable チェーン（通知 10 件分割） | 通常の Active Job（分割不要） |
| Batch Apex（月次一括確定） | Active Job + `find_each`（分割は性能判断） |
| GatchaInstallHandler（初回スケジュール） | recurring.yml（コード同梱・組織オンボーディングは seed） |

---

## 11. 監査証跡・データ保持

### 11.1 監査証跡

`AttendanceHistory`（§4.14・追記専用）が主要監査ログ。打刻変更・休暇承認/撤回・遅刻早退フラグの前後値・代理打刻・欠勤確定・インターバル不足を完全記録。任意時点の勤怠状態を再現可能。補完として Postgres トリガー or `paper_trail` を主要モデルの status / 時刻に併用してもよい（法的根拠は `AttendanceHistory`、`paper_trail` は補助）。

### 11.2 法的保存要件

| 根拠 | 対象 | 保存 |
|------|------|------|
| 労基法 109 条（2020 改正） | 出勤簿・賃金台帳相当 | **5 年**（猶予中は 3 年可だが 5 年に統一） |
| 同施行規則 24 条の 7 | 有給休暇管理簿 | 3 年（5 年に統一） |
| 個人情報保護法 | 期間超過データ | 削除 or 匿名化義務 |

方針: **5 年保持 → 経過後アーカイブ（匿名化 or 外部退避）→ 本体削除**。

### 11.3 オブジェクト別保持

| モデル | 保持 | 期間後 |
|--------|------|--------|
| AttendanceRecord | 確定月から 5 年 | 退避 → 削除 |
| AttendanceHistory | 5 年 | 退避（匿名化推奨） |
| LeaveRequest / ClockChangeRequest | 5 年 | 退避 → 削除 |
| MonthlyAttendanceSummary | **永久** | 削除不可 |
| NotificationDelivery | 90 日 | 削除 |
| LeaveBalance | 退職後 5 年 | 削除 |
| UserWorkPattern | 退職後即時論理削除 | active=false |

### 11.4 アーカイブ実装

- **基点:** `MonthlyAttendanceSummary.status=finalized` かつ確定月が 5 年超のレコードに紐づく明細
- **方式（Rails での選択肢）:** ① Postgres 宣言的パーティショニング（年/月）で古いパーティションを detach → 外部退避、② 専用アーカイブテーブルへ移送、③ S3 等へエクスポート + 本体削除
- **冪等性:** `archived` フラグで二重処理防止。退避先への書き込み成功を確認してから削除
- **実行:** 月次バッチ（`MonthlyComplianceJob` 内 or 専用ジョブ）

---

## 12. UI（Hotwire）

すべてサーバーレンダリング + Turbo。再利用単位は ViewComponent。リアルタイム更新（打刻状態・通知ベル）は Turbo Streams（SolidCable）。

### 12.1 社員ホーム画面

| エリア | 内容 |
|--------|------|
| ヘッダー | 本日日付・曜日、打刻ステータス（未出勤/出勤中/退勤済/休暇）、出勤/退勤ボタン（状態で切替） |
| 申請ステータス | 直近の休暇・打刻変更申請、status バッジ、新規申請リンク |
| 休暇残高 | paid_leave 種別の付与/使用/残日数。振替休日・代休は残高あれば強調 |
| カレンダー | 当月を色分け（出勤=青/休暇=緑/半休=黄/欠勤=赤/未打刻平日=グレー）、前後月切替 |
| 通知設定 | 抑制 ON/OFF・時間帯・休日ブロック。変更は即時 `UserNotificationPreference` 保存 |

集計は当月サマリ=`MonthlyAttendanceSummary` 基点、直近打刻（14 日）=`AttendanceRecord` 直接。長期は必ずサマリ経由。

### 12.2 管理ダッシュボード

確認頻度で 3 セクション化（各セクションに未対応バッジ）:

- **緊急（毎日）:** 未承認申請（段階別件数）・打刻漏れ・欠勤候補一覧（欠勤確定の起点）
- **重要（週次）:** 残業統計（60h 接近ハイライト）・36 協定管理タブ・連続勤務超過・インターバル違反・全員カレンダー・遅刻早退統計
- **管理（月次）:** 月次未提出者・有給 5 日未取得者（期限超過は別セクション）・有給失効予定者・パターン未割当者・産業医面談管理

> **Rails での解放:** SF は「標準レポート 2,000 行上限」「OFFSET 2,000 上限」「SOQL 50,000 行」に縛られダッシュボードを全て LWC で自作していた。Rails は通常の SQL + ページネーション（kaminari 等）で素直に実装でき、行数制限の設計負荷は消える。`AttendanceHistory` の大量参照もインデックス + キーセット/オフセットを性能で選べる。

### 12.3 マスタ管理

タブ型（ViewComponent）。勤務パターン・休暇種別・会社カレンダー（CSV 一括インポート・RFC 4180）・パターン割当・休暇残高の CRUD・インライン編集・無効化。Pundit で `hr_admin` に限定。

### 12.4 モバイル / PWA

レスポンシブ + PWA（ホーム追加・オフライン打刻キューは将来）。打刻ボタンは大きめ。SF Mobile App 依存を排し、ブラウザで完結。

---

## 13. 状態遷移（AASM）

SF 版 Mermaid 図（§13）を AASM 定義へ対応づける。

- **AttendanceRecord.status:** working →（退勤）clocked_out。休暇承認で on_leave / morning_half / afternoon_half。欠勤確定で absent。absent →（打刻追加承認）working、（事後有給）on_leave
- **LeaveRequest / ClockChangeRequest.approval_status:** applying →（承認）approved /（却下）rejected /（キャンセル）canceled。approved →（撤回操作）withdrawal_requested →（撤回承認）withdrawn /（撤回却下）approved。段階（第 1/第 2）は `ApprovalAssignment` から導出（status には持たない）
- **MonthlyAttendanceSummary.status:** aggregating → submitted ⇄ deferred、submitted → finalized → deferred（§6.6）

各 AASM イベントの `after` フックで副作用サービス（承認・撤回復元・再集計）を呼ぶ。

---

## 14. Gatcha Work 連携の継ぎ目

SF 版は `LeaveApproved__e` / `LeaveRevoked__e`（Platform Event）で疎結合連携していた。Rails では **Outbox パターン**で同等の継ぎ目を残す（本サイクルでは publish 側のみ実装、subscriber は Gatcha Work 側の将来責務）:

1. 休暇承認/撤回時、同一トランザクションで `IntegrationEvent`（`leave_approved` / `leave_revoked`、payload に user_id・対象日・工数時間・休暇種別）を作成
2. `after_commit` で配信ジョブが未配信イベントを Gatcha Work へ通知（Webhook or `ActiveSupport::Notifications`、将来はメッセージブローカ）
3. 単独運用時は subscriber 不在でも publish はテーブルに残るだけ（データ損失なし）

> SF の「Platform Event は同期トリガー内で 1 回だけ publish・Queueable 内禁止」という制約は、Outbox + after_commit で「1 トランザクション 1 イベント・確実に 1 回」を自然に担保。

---

## 15. 実装ロードマップ

全仕様を一括実装せず、以下のフェーズで段階構築する（各フェーズは独立に価値を生む）。

| Phase | 内容 | 主要成果物 |
|-------|------|-----------|
| **0 基盤** | Rails 8 / Postgres / acts_as_tenant / Devise / Pundit / ロール・上長 / マスタ CRUD | Organization, User, 各 Master, OrganizationSetting |
| **1 打刻** | 出退勤打刻 + 計算オブジェクト群 + 社員ホーム | AttendanceRecord, WorkTime/Overtime/DeepNight/LateEarly Calculator |
| **2 申請・承認** | 休暇申請 + 残高 + 承認エンジン + 打刻変更 + 休日出勤 + 撤回 | LeaveRequest, LeaveBalance, Approval\*, ClockChangeRequest, HolidayWorkRequest |
| **3 締め** | 月次サマリ + 締め状態機械 + CSV 出力 | MonthlyAttendanceSummary, MonthlySummaryService |
| **4 コンプラ・通知** | 36 協定 / インターバル / 連続勤務 / 有給 5 日 / 産業医 + 通知基盤 + バッチ | ComplianceService 群, Notification\*, SolidQueue recurring |
| **5 管理・監査** | 管理ダッシュボード + 監査/保持 + Gatcha Work 連携の継ぎ目 | Admin UI, AttendanceHistory 保持, IntegrationEvent |

各フェーズは brainstorming → writing-plans → 実装のサイクルで進める。

---

## 16. 付録：Salesforce → Rails 対応表（早見）

| Salesforce | Rails | 備考 |
|-----------|-------|------|
| Custom Object（`__c`） | ActiveRecord モデル | snake_case カラム |
| Lookup(User) | `belongs_to :user` | FK |
| Apex Trigger（複雑） | Service Object | 軽微のみ AR callback |
| 標準 User オブジェクト | `User`（Devise）+ `organization_id` | 自前認証 |
| OWD Private / 共有ルール / Apex Managed Sharing | acts_as_tenant + Pundit Scope | 2 層に集約 |
| Permission Set ×3 | `role` enum + Pundit Policy | employee/manager/hr_admin |
| `without sharing` + ElevatedDml（Path C 5 層） | Pundit ポリシー | 「sharing 迂回」概念が消滅 |
| `IsManagerRole__c` | `exempt_from_overtime`（管理監督者） | 割増計算の分岐 |
| Custom Metadata Type | `OrganizationSetting`（型付きテーブル） | テナント別・1 行 |
| 標準承認プロセス | ApprovalRoute/Step + AASM | テナント別に柔軟 |
| Custom Notification（ベル・10/txn） | Notification + Turbo Streams | 上限なし |
| NotificationQueue__c | NotificationDelivery + ActiveJob `wait_until` | 抑制後送 |
| Platform Event（`__e`） | IntegrationEvent（Outbox）+ after_commit | 確実に 1 回 |
| Scheduled/Queueable/Batch Apex | SolidQueue + recurring.yml | 制約なし |
| Field History Tracking（18 ヶ月削除） | AttendanceHistory（5 年）+ paper_trail（補助） | 法的根拠は前者 |
| Formula フィールド | 算出メソッド / 生成列 | 残日数・取得義務期限 |
| LWC | Hotwire + ViewComponent | サーバーレンダリング |
| ガバナ制限（DML/SOQL/OFFSET/CPU/Batch） | — | 通常のトランザクション |
| 2GP / InstallHandler / namespace | デプロイ型 SaaS / seed | パッケージング概念が消滅 |
| Big Objects（アーカイブ） | Postgres パーティション / S3 退避 | §11.4 |

---

## 改訂履歴

| 日付 | 内容 |
|------|------|
| 2026-06-09 | 初版。SF 2GP 版 Gatcha（勤怠ドメイン）を Rails 8 マルチテナント SaaS 向けに再設計 |

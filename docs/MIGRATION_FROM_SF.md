# 付録: Salesforce 版 Gatcha からの移植対応表

> 本書は**歴史的経緯の記録**である。docs/SPEC.md は本書なしで自立して読める（仕様の理解に本書は不要）。
> 移植の漏れ・意図を原典と突合する際にのみ参照すること。
>
> - **移植元:** Salesforce 2GP マネージドパッケージ版 Gatcha（勤怠ドメイン）。原典仕様書は別リポジトリ `../Gatcha/docs/SPEC.md`（手元に無くても本書・SPEC.md の理解には不要）
> - **移植方針:** 労務コンプライアンスのドメインロジックは一片も削らず、Salesforce 固有の実装制約（ガバナ制限・2GP・Platform Event・LWC・標準承認プロセス・共有モデル）を Rails のイディオムへ翻訳した
> - **状態遷移図:** SF 版 SPEC §13 の Mermaid 図は、Rails の状態名へ描き直して SPEC.md §13 にインライン化済み（本書への依存なし）

## 1. アーキテクチャ前提の違い（再設計の出発点）

| 観点 | Salesforce 版 | Rails 版（SPEC.md） |
|------|--------------|-------------------|
| テナント | 1 社 1 組織（シングルテナント） | **マルチテナント SaaS**（行レベル分離・単一 DB） |
| ユーザー | 標準 `User` オブジェクト | **自前 `User` モデル**（Devise）+ `organization_id` |
| 認可 | OWD + 共有ルール + Permission Set + Path C 5 層 | **テナントスコープ + Pundit ポリシー**（2 層） |
| 配布 | 2GP マネージドパッケージ（AppExchange） | **デプロイ型 SaaS**（「インストール」= 組織オンボーディング） |
| 実装制約 | ガバナ制限（DML 150 / SOQL 50000 / OFFSET 2000 / CPU 10s / Batch 5 / 通知 10/txn） | **制約なし**（通常の DB トランザクション） |

ガバナ制限に由来する SF 版の回避策（再帰ガード・Bulkification 必須・OFFSET 禁止・Queueable チェーン分割・同期/非同期の承認分離）は Rails へ持ち込まない（SPEC.md §2.2-5）。

## 2. 概念対応表（早見）

| Salesforce | Rails | 備考 |
|-----------|-------|------|
| Custom Object（`__c`） | ActiveRecord モデル | snake_case カラム（例: `ClockIn__c` → `clock_in`、`IsActive__c` → `active`） |
| Lookup(User) | `belongs_to :user` | FK |
| Apex Trigger（複雑） | Service Object | 軽微のみ AR callback |
| 標準 User オブジェクト | `User`（Devise）+ `organization_id` | 自前認証 |
| OWD Private / 共有ルール / Apex Managed Sharing | acts_as_tenant + Pundit Scope | 2 層に集約 |
| Permission Set ×3 | `role` enum + Pundit Policy | employee/manager/hr_admin |
| `without sharing` + ElevatedDml（Path C 5 層） | Pundit ポリシー | 「sharing 迂回」概念が消滅 |
| `IsManagerRole__c` | `exempt_from_overtime`（管理監督者） | 割増計算の分岐 |
| OwnerId 明示セット（OWD=Private 下の当事者アクセス） | `user_id` + Pundit スコープ | オーナーと操作者の分離（SPEC.md §3.5） |
| `DateUtil.getUserLocalDate()` | `in_time_zone(org.time_zone)` | 労働法判定の TZ 変換 |
| Custom Metadata Type（AttendanceSettings__mdt） | `OrganizationSetting`（型付きテーブル） | テナント別・1 行 |
| 標準承認プロセス | AASM + ApprovalAssignment（固定 2 段） | v1 は manager 階層固定・ルート設定化は v2 |
| Custom Notification（ベル・10/txn） | Notification + Turbo Streams | 上限なし |
| NotificationQueue__c | NotificationDelivery + ActiveJob `wait_until` | 抑制後送 |
| Platform Event（`LeaveApproved__e` / `LeaveRevoked__e`） | after_commit フック点（Outbox は v2） | v1 は継ぎ目の位置のみ |
| Scheduled Apex（日次/週次） | SolidQueue recurring task | `config/recurring.yml` |
| Queueable チェーン（通知 10 件分割） | 通常の Active Job | 分割不要 |
| Batch Apex（月次一括確定） | Active Job + `find_each` | 分割は性能判断 |
| GatchaInstallHandler（初回スケジュール） | recurring.yml（コード同梱・組織オンボーディングは seed） | パッケージング概念が消滅 |
| Field History Tracking（18 ヶ月削除） | AttendanceHistory（5 年）+ paper_trail（補助） | 法的根拠は前者 |
| Formula フィールド | 算出メソッド / 生成列 | 残日数・取得義務期限 |
| LWC | Hotwire + ViewComponent | サーバーレンダリング |
| 標準レポート / SOQL 行上限（ダッシュボード自作の要因） | 通常の SQL + ページネーション | 行数制限の設計負荷が消滅 |
| ガバナ制限（DML/SOQL/OFFSET/CPU/Batch） | — | 通常のトランザクション |
| 2GP / InstallHandler / namespace | デプロイ型 SaaS / seed | パッケージング概念が消滅 |
| Big Objects（アーカイブ） | Postgres パーティション / S3 退避 | SPEC.md §11.4 |

## 3. ロール・権限の対応（SPEC.md §3.3 の出自）

| SF | Rails |
|----|-------|
| AttendanceUser PS | `role: :employee` |
| AttendanceManager PS | `role: :manager` |
| AttendanceAdmin PS | `role: :hr_admin` |
| `User.IsManagerRole__c`（管理監督者・労基法 41 条） | `User#manager_supervisor?`（`exempt_from_overtime` フラグ） |
| ロール階層 / `User.ManagerId` | `User belongs_to :manager, class_name: 'User'`（自己参照 `manager_id`） |

SF 版でも `IsManagerRole__c` は割増計算の分岐に使われ、Permission Set とは独立していた。`role`（システム権限）と `exempt_from_overtime`（労働法上の地位）の分離（SPEC.md §3.3）はこの構造を引き継いだもの。

## 4. 移植時に SF 版から引き継いだ設計判断（補足メモ）

- **承認ステータスの状態機械はカスタム実装:** SF 標準承認プロセスの Reject は「却下・終了」で「差戻し→修正→再提出」ループに不適合だった。Rails でも同じ理由でカスタム遷移とする（SPEC.md §6.6）
- **「第 1/第 2 段階承認待ち」を status に持たない:** SF 標準承認プロセスが内部管理していた段階状態を、Rails では `ApprovalAssignment` からの導出に置き換えた（SPEC.md §7.1・§13）
- **計算列の常時保存:** SF 版の「常時保存」運用（CSV 出力・集計の再計算回避）を引き継いだ（SPEC.md §4.8）
- **`LeaveBalance` の行ロック:** SF 版の `FOR UPDATE` を `ActiveRecord#lock!` にそのまま翻訳（SPEC.md §4.10）
- **計算ロジックの PORO 化:** SF 版では Apex トリガー内に計算が埋もれ検証が困難だった反省から、AR 非依存の計算オブジェクトへ分離（SPEC.md §2.2-1・§5）

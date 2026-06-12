# Phase 1-1 設計 — AttendanceRecord + 打刻（出退勤ボタン・社員ホーム §12.1 最小）

> 対象: docs/ROADMAP.md 1-1 ／ SPEC §4.8・§6.1・§5.4（未割当スキップ）・§12.1
> 体制: 折衷案 v2（設計/計画/スペック準拠 = 主エージェント・実装 = サブエージェント・品質 = 独立サブエージェント）の 5 効率化項目の実証スライス
> ユーザー決定（2026-06-12）: スキーマ = 消費分のみ ／ 退勤後 = 両ボタン無効 ／ ホーム = 当月色分け + 前後月切替 ／ 未割当 = ホーム警告バナー
> 多視点レビュー反映（同日・5 視点）: redirect 方式へ変更 ／ AASM = enum + 逸脱宣言 ／ 退勤忘れバナー前倒し ／ clock_in NOT NULL ほか（各節に注記）

## §0 方針・前提（SPEC 確定事項の再掲 + 宣言）

- **パターンスナップショット（§4.8・§6.1）**: 出勤打刻時に `UserWorkPattern.effective_on(org.today)` で有効割当を引き、`work_pattern_id` に確定保存。以後の割当変更は当日に影響しない（不遡及）
- **未割当でも打刻許可（§5.4）**: 有効割当ゼロなら `work_pattern_id: NULL` で保存（計算は 1-2 がスキップ）。管理者通知は Phase 4。遡及補正は ROADMAP バックログ（社労士確認 #12-(a) — 再判断トリガーは Phase 4-1 着手前。本 PR の docs 逆反映で NOTES を更新）
- **夜勤は出勤日で統一（§4.8）**: `work_date` = 出勤打刻時点の `Organization#today`。日付を跨いだ退勤は前日の出勤レコードに合流する（昭 63.1.1 基発 1 号と整合 — 労務レビュー照合済み）
- **「今日」の単一ソース**: 全箇所 `Organization#today`（組織 TZ）。`Date.current` は JST 0:00〜8:59 に前日を返すため禁止（0b-4 設計 §0）
- **AASM 逸脱宣言（原則レビュー反映）**: SPEC §13.1 は status を AASM 状態機械として図示するが、1-1 は 2 状態のため **plain enum で開始**する意図的逸脱を採る。AASM 化の再判断は**状態が 3 つ以上になる 2-2**（同時に §13.6「副作用はイベントに紐付ける」の置き場 — サービス直列 vs AASM after — も確定する）。SPEC §13 へ実装注記を本 PR の docs 逆反映で amend
- **時刻不変条件（労務レビュー反映）**: 打刻時刻はサーバー側 `Time.current` のみ（クライアント時刻不受理）。**1-3（AttendanceHistory）出荷前に時刻変更・上書き経路を追加しない** — 証跡なし改変経路ゼロを 109 条・適正把握の趣旨に対する設計上の不変条件とする
- 1-2（計算列・算出）・1-3（代理打刻・note・AttendanceHistory）はこのスライスに含めない。継ぎ目だけ作る

## §1 データモデル — attendance_records（消費分のみ 6 カラム）

0b-5 で確立した「消費済みカラムのみ」原則を適用。§4.8 の残カラム（計算列 6 本・フラグ 4 本・absence_reason・proxy_clock_reason・note・archived）は消費スライス（1-2/1-3/2-4/4-2/Phase 5）のマイグレーションで追加する。

| カラム | 型 | 制約 |
|--------|-----|------|
| organization_id | bigint | NOT NULL・FK organizations |
| user_id | bigint | NOT NULL・複合 FK (organization_id, user_id) → users(organization_id, id) |
| work_date | date | NOT NULL |
| clock_in | timestamptz | **NOT NULL**（1-1 の全行は打刻起源。on_leave/absent の NULL 意味論は 2-2 が消費と同時に緩和 — YAGNI レビュー反映・§6 継ぎ目） |
| clock_out | timestamptz | NULL 許容（出勤中は NULL） |
| work_pattern_id | bigint | NULL 許容（未割当打刻）・複合 FK (organization_id, work_pattern_id) → work_patterns(organization_id, id) |
| status | integer | NOT NULL |

**インデックス:**
- `[user_id, work_date]` **unique** — 二重打刻防止の背骨。user_id はグローバル一意 PK ゆえテナント越境なしで全域一意が安全（②型の発想）
- `[organization_id, id]` unique — 後続スライス（LeaveRequest 等）の複合 FK 受け皿（確立パターン・全テナントテーブルがテーブル作成時に保持。attendance_records は最大テーブルになるため後付けが最も高コスト）
- `[organization_id]`（acts_as_tenant 用）

**モデル `AttendanceRecord`:**
- `acts_as_tenant(:organization)` / `belongs_to :user` / `belongs_to :work_pattern, optional: true`
- `enum :status, { working: 0, clocked_out: 1 }, validate: true` — 残り 4 値は §4.8 の列挙順で整数を予約（morning_half: 2 / afternoon_half: 3 / on_leave: 4 / absent: 5）するコメントを付し、消費スライスで追記。整数マッピング固定の spec example を置く（0b-5 ReasonTemplate と同型）
- **述語の唯一ソース（YAGNI レビュー反映）**: 打刻状態の判定スコープをモデルに置き、サービスと `Clockings::State` は**必ずこれを経由**する（並行実装で述語が割れることを構造的に禁止）:
  ```ruby
  # 退勤対象・出勤ガード・ホーム表示の単一述語源。window = 夜勤の日付跨ぎ退勤を
  # 前日レコードに合流させるための探索範囲（SPEC §4.8 夜勤は出勤日統一）
  scope :working_within, ->(window) { where(status: :working, work_date: window) }
  ```
- 検証: `work_date` presence ／ `clock_in` presence ／ `clock_out_after_clock_in`（`clock_out >= clock_in`。夜勤は timestamptz 比較ゆえ自然に成立）
- `validates_uniqueness_to_tenant` は使わない — `[user_id, work_date]` のグローバル unique index + RecordNotUnique rescue（§2）が一次防衛。モデル検証の uniqueness は TOCTOU で race に勝てないため重複させない
- work_pattern の越境検証: 書き込みは §2 のサービス経由のみ（mass-assignment なし・スナップショット元が effective_on スコープ = テナント内の二重保証済み）ゆえ UserWorkPattern 型の fail-closed 検証は置かない。複合 FK が最終防衛。**モデルに意図コメント必須**（セキュリティレビュー反映）:「work_pattern_id の書き込みはスナップショットサービス限定。直接代入経路（1-3 代理打刻・2-3 変更承認）を作る場合は fail-closed 検証を追加すること」

## §2 打刻サービス — Clockings::ClockIn / Clockings::ClockOut / Clockings::State

§2.2「複雑ロジックは Service」。1-2 の計算呼び出しは ClockOut（と打刻変更承認）に後付けされるため、ここがその継ぎ目。戻り値は 0b-5 Updater と同じ `Data.define(:success, :record, :error) { def success? = success }`。

**共通規約（レビュー反映）:**
- 操作対象は常に呼び出し側の current_user — user_id をパラメータから受けない
- **全クエリは `user.attendance_records` 起点**（セキュリティレビュー反映 — 同一テナント内の他人の working を退勤させる経路を構造的に遮断）+ §1 の `working_within` スコープ経由
- 本体を `ActsAsTenant.with_tenant(user.organization)` で自己完結（console/将来ジョブから呼ばれても自社の行しか触れない — OrganizationSettings::Updater と同じ前例対称・原則レビュー反映）
- window 定義 = `(org.today - 1)..org.today`。`Clockings::State` と 3 サービスで同一定数を共有

**`Clockings::ClockIn.call(user:)`**
1. `org = user.organization` / `today = org.today`
2. ガード: 同日レコード存在 → failure(:already_clocked_in) ／ window 内 working 存在 → failure(:still_working)
3. スナップショット: `user.user_work_patterns.effective_on(today).first&.work_pattern_id`（active の重複は exclusion constraint で排除済みゆえ高々 1 件）
4. `user.attendance_records.create!(work_date: today, clock_in: Time.current, work_pattern_id:, status: :working)`
5. `ActiveRecord::RecordNotUnique` rescue → failure(:already_clocked_in) に合流（同時タブ・モバイル二重タップのサーバー側防衛 §6.1）

**`Clockings::ClockOut.call(user:)`**
1. 対象 = `user.attendance_records.working_within(window).order(work_date: :desc).first`
   - work_date でなく status 起点にするのが夜勤対応の要 — 日付跨ぎ退勤が前日レコードに合流
   - window 外（2 日以上前）の取り残し working は対象外 — 4-2 打刻漏れバッチの検出対象として温存（誤った当日退勤の混入を防ぐ）
2. 対象なし → failure(:not_working)
3. `record.with_lock { working 再確認（負けたら failure(:not_working)）→ update!(clock_out: Time.current, status: :clocked_out) }` — 同時タブ race を行ロックで直列化
4. 退勤済み後の再打刻は出勤・退勤とも不可（ユーザー決定）。時刻修正は Phase 2-3 打刻変更申請に一本化（§0 の時刻不変条件）

**`Clockings::State`（PORO・app/services/clockings/state.rb）** — ヘッダー・ボタン活性・バナーの導出を一手に担う読み取り専用オブジェクト。サービスのガードと同じ述語（`working_within`・同日行）を共有し、UI とサーバー検証の判定が割れない
- `today_record`（org.today の行）・`working_record`（window 内 working）・**`stale_working_record`（window より前の working — 退勤忘れバナー用・労務レビュー反映）** の 3 クエリ（すべて `user.attendance_records` 起点）
- 表示状態: working_record あり → 出勤中 ／ today_record が clocked_out → 退勤済 ／ どちらもなし → 未出勤
- 出勤ボタン活性 = today_record なし **かつ** working_record なし ／ 退勤ボタン活性 = working_record あり

**failure メッセージ文言（Pragma レビュー反映・ja.yml）:**
- :already_clocked_in →「すでに出勤済みです」（§6.1 原文）
- :still_working →「前日の退勤が記録されていません。先に退勤を打刻してください」
- :not_working →「出勤打刻がありません。過去日の退勤時刻は打刻変更申請（Phase 2 で提供予定）で記録します。それまでは管理者に連絡してください」

## §3 認可

`ClockingPolicy`（headless・`authorize :clocking, :clock_in?`）: `clock_in?` / `clock_out?` は `user.present?`（HomePolicy と同型の深層防御 — literal true にしない・セキュリティレビュー反映）。全ロール打刻可能（employee も hr_admin も自分の打刻は等しく可能 — 管理監督者も記録対象である労基法上の整理とも整合）。

**補償統制コメント必須**（organization_setting_policy.rb の前例同型・セキュリティレビュー反映）: Scope を定義しない理由（操作対象はコントローラ構造で current_user 固定・一覧系データ取得は `current_user.attendance_records` 起点を必須とする）・将来の一覧/管理画面（管理ダッシュボード §12.2 等）では AttendanceRecordPolicy + Scope を必ず新設すること、を明記。代理打刻（1-3）は別コントローラ・別ポリシーで作る。

## §4 UI — 社員ホーム（§12.1 最小）

**ルーティング:**
```ruby
resource :clocking, only: [] do
  post :clock_in
  post :clock_out
end
# root "home#show" は既存。月切替は GET root（?month=YYYY-MM）
```

**HomeController#show 拡張:**
- `@state = Clockings::State.new(user: current_user)`（ヘッダー + ボタン + バナー）
- `@month = params[:month] 解析`（不正値・範囲外は org.today の月へフォールバック）
- カレンダー用データ: 当月の AttendanceRecord（**`current_user.attendance_records` 起点**・work_date 範囲・1 クエリ）+ **`CompanyCalendarResolver#day_types(from, to)`**（範囲一括 1 クエリ・未登録日の ISO 曜日フォールバック内蔵 — §4.7 の確立実装を再利用し判定を二度書きしない）→ `Home::CalendarComponent` へ

**ClockingsController**（clock_in / clock_out）:
- `authorize :clocking, :xxx?` → サービス call → **`redirect_to root_path, status: :see_other`**（成功 = flash.notice ／ 失敗 = flash.alert にメッセージ）
- **Turbo Stream は採用しない**（Pragma/YAGNI レビュー反映）: 既存コードベースは全面「redirect + flash + see_other」で統一されており、redirect ならボタン活性・カレンダー当日セル・バナーすべてが State から再計算され stale 画面が構造的に消える。Turbo Drive 配下ゆえ体感も十分。SolidCable によるマルチタブ同期はヘッダー partial の部品化だけで継ぎ目が残る
- 連打防止 UI は Turbo 標準の submit 中 disable（button_to）+ サーバーレンダリングの disabled 状態。Stimulus 自作はしない

**ヘッダー（partial `home/_clocking.html.erb`）:**
- 本日日付・曜日（org.today・I18n）・打刻ステータスバッジ（未出勤/出勤中/退勤済）
- 出勤・退勤ボタン（`button_to`・状態に応じ disabled）。退勤済時は「時刻の修正は打刻変更申請で行えます（Phase 2 で提供予定）」注記
- **未割当警告バナー**: `UserWorkPattern.effective_on(org.today)` が空なら「勤務パターンが割り当てられていません。打刻は記録されますが労働時間が計算されません。管理者に連絡してください」（0b-4 社員詳細バナーと同型・E 原則）
- **退勤忘れ警告バナー（労務レビュー反映・ユーザー承認）**: `stale_working_record` ありなら「{work_date} の退勤記録がありません。管理者に連絡してください」

**カレンダー（`Home::CalendarComponent`）:**
- 当月グリッド（週開始は日曜 — 暦週の行政解釈と整合・前後月の余白セルは空）+ 前月/翌月ナビ（`?month=`）
- 分類（1-1 で判定可能なものだけ）: 出勤中（当日 working）／退勤済／**過去日 working（退勤忘れの取り残し — Pragma レビュー反映・退勤済と同系の表示）**／過去の未打刻平日=グレー／休日／未来日・当日未打刻=素。休暇=緑/半休=黄/欠勤=赤 は Phase 2/4-2 で追加
- 休日スタイルは **1 種**（YAGNI レビュー反映 — §12.1 は休日種別の視覚区別を要求しない）。day_type が :weekday 以外（saturday/sunday/holiday/company_holiday/legal_holiday）を「休日」に縮約
- 「平日」判定 = `CompanyCalendarResolver` の day_type が :weekday（未登録日は ISO 曜日フォールバック — 行が無い土日を「未打刻平日グレー」に誤分類しない）
- 分類ロジックは component 内の private メソッド（日 → 分類 symbol）に隔離し component spec で網羅

## §5 テスト

- **model**: 整数マッピング固定（working:0/clocked_out:1）・clock_out 逆転 422・unique index（同 user 同日 2 行目で RecordNotUnique）・`working_within` スコープ・acts_as_tenant
- **service ClockIn**: スナップショット確定（割当ありで work_pattern_id 一致）・未割当 NULL 保存・同日 2 回目 failure・window 内 working 中 failure・**同一 org の他人の同日行/working に反応しない**（セキュリティレビュー反映）・RecordNotUnique → already_clocked_in 合流・**TZ 境界**（JST 8:59 = UTC 前日 23:59 に org.today が JST 当日を返し work_date がズレない）
- **service ClockOut**: 当日退勤・**夜勤跨ぎ**（前日 working に翌日退勤が合流・work_date は前日のまま）・window 外 working 無視（3 日前 working は not_working）・**同僚の working が在っても not_working**・退勤済後 failure・with_lock 下の再確認
- **request**: clock_in/clock_out の 303 redirect + flash・未ログイン redirect・**パラメータに他人の user_id を混ぜても current_user に記録される**・退勤済後の POST が失敗 flash
- **component**: 全分類（出勤中/退勤済/過去日 working/過去未打刻平日/休日/未来/前後月余白）・月境界（月初が日曜でない月・2 月）・月パラメータ不正値フォールバック
- **policy**: 全ロール clock_in?/clock_out? true・未ログイン（user nil）false

## §6 スコープ外（後続接続の継ぎ目）

| 項目 | 行き先 | 継ぎ目 |
|------|--------|--------|
| 計算列 + 算出・保存 | 1-2 | ClockOut サービス内に呼び出しを後付け。**深夜帯は隣接 2 窓（[D−1 22:00, D 5:00] + [D 22:00, D+1 5:00]）の overlap 合算が必要**（労務レビュー W1 — SPEC §5.3 の補正は本 PR の docs 逆反映で実施） |
| clock_in の NULL 意味論（on_leave/absent） | 2-2/4-2 | NOT NULL を消費スライスが緩和（1 行 migration） |
| AASM 化 + 副作用のイベント紐付け方針 | 2-2 で再判断 | §0 の逸脱宣言・SPEC §13 実装注記 |
| 代理打刻・note・proxy_clock_reason・AttendanceHistory | 1-3 | 別コントローラ/ポリシー・カラム追加。**1-3 まで時刻変更経路を作らない**（§0 不変条件） |
| 半休/休暇/欠勤ステータス + カレンダー色 | 2-2/4-2 | enum 追記（整数予約済み）・component 分類追加 |
| 打刻漏れ検知・未割当の管理者通知 | 4-2/4-1 | window 外 working の温存 + stale バナー・effective_on 述語 |
| マルチタブのリアルタイム同期（SolidCable） | 必要時 | ヘッダー partial の部品化（導入時は signed per-user stream 必須 — セキュリティレビュー注記） |

## §7 docs 逆反映（本 PR に同梱）

1. **SPEC §13**: 「実装注記（1-1）: AttendanceRecord.status は 2 状態の間 plain enum。AASM 化は状態が 3 つ以上になる 2-2 で再判断（§2.2-3 の列挙は申請・締めのみで両立）」を追記
2. **SPEC §5.3**: 深夜帯の窓を「出勤日の 22:00〜翌 05:00」単窓から**隣接 2 窓の overlap 合算**へ補正（早朝シフトの出勤日当日 0:00〜5:00 帯の取りこぼし防止 — 労基法 37 条 4 項「午後十時から午前五時まで」原典照合済み）
3. **LABOR_LAW_REVIEW_NOTES**: #14（夜勤の法定休日跨ぎ — 35 条暦日主義との交差・1-2/2-4 設計前に確認）・#15（同日再出勤/中抜け勤務の記録経路）を新規追記、#12-(a) に再判断トリガー「Phase 4-1 着手前」を追記（労務レビュアー起こしの文面を使用）
4. **ROADMAP**: 1-1 行チェック + PR 番号（マージ前に同梱）
5. **RAILS_GOTCHAS**: 実装中に新しい罠が出た場合のみ

# Phase 0b-4（UserWorkPattern）設計仕様

- 日付: 2026-06-12（多視点レビュー反映済み: 原則整合・実用主義・YAGNI・テナント分離・**労務法令**の 5 視点並列）
- 対象: ROADMAP Phase 0b-4。勤務パターン割当 CRUD・期間重複バリデーション（SPEC §4.6）・割当済み WorkPattern の無効化ガード（0b-2 設計 §0 からの宿題）
- 上位文書: [docs/SPEC.md](../../SPEC.md)（§3.6・§4.6・§4.8・§8 冒頭 E 原則・§16.7）/ [docs/ROADMAP.md](../../ROADMAP.md) / [docs/RAILS_GOTCHAS.md](../../RAILS_GOTCHAS.md)
- 法令出典: 労基法 <https://laws.e-gov.go.jp/law/322AC0000000049>（109 条・61 条 1 項・32 条の 3 は設計段階で jp-labor-evidence により原典照合済み・2026-06-12。143 条は取得失敗＝未照合）・労安法 <https://laws.e-gov.go.jp/law/347AC0000000057>（66 条の 8 の 3）
- 前提: 0b-1〜0b-3 の Admin 資産（BaseController・MasterPolicy・policy_scope 経由 find・303 redirect・enum/validate 規約・複合 FK パターン）

## 0. スコープと確定済み判断

| 論点 | 決定 |
|---|---|
| WorkPattern 無効化ガード | **ガード②同型で拒否**（User の「アクティブ部下あり拒否」と同型）。今日以降も有効な割当が 1 件でもあれば無効化拒否。過去のみの割当は妨げない |
| 重複の防衛層 | **モデル検証 + PostgreSQL exclusion constraint の二重防衛**。SPEC §4.6 は「モデルバリデーション」のみ指定だが、Phase 1 の「打刻日時点で有効な 1 件」取得が重複データで 2 件返ると賃金計算の入力が非決定化するため DB 層バックストップを採用（SPEC へ逆反映 §7） |
| 削除方針 | **無効化のみ**（destroy ルートなし・User 同型）。**意味論を一本化: `active=false` は誤登録の論理削除専用・正常な終了/切替は `end_date` で表現**（切替 = 旧割当の end_date 設定 → 新規作成の 2 ステップ）。過去割当は Phase 1 の「未打刻日の所定根拠」として温存 |
| activate（再有効化） | **残す（検証完備で）**: 重複検証は「保存後に active である create/update すべて」で発火（activate = `update(active: true)` も自然に通過）・exclusion 違反 rescue は create/update/activate の 3 アクション全部に掛ける |
| UI 配置 | **社員詳細にネスト** `/admin/users/:user_id/user_work_patterns`。index/show なし（一覧は社員詳細に同居）。ナビのタブは増やさない |
| 未割当の可視化 | **社員詳細バナーのみ**（§16.7 オンボーディング手順 4 の補助が採用根拠）。文言は「**計算不能・判定スキップ**になる」— SPEC §8 冒頭の E 原則「打刻のブロックは一切行わない」に従い「打刻不能」とは書かない（労務レビュー Critical 反映）。述語は Phase 1 取得条件と同一の scope に一本化（§2）。社員一覧のバッジ列・期限切れ先読みはバックログへ（YAGNI 指摘採用） |
| 「今日」の TZ 契約 | `config.time_zone` 未設定（UTC）のため `Date.current` は JST 0:00〜8:59 に前日を返す。**`Organization#today`（組織 TZ における当日 Date）を新設し、§3 ガード・§5 表示分類・未割当バナーの 3 箇所すべてをこれ経由に一本化**。判定はレコードの organization から導出（current_tenant 不使用 — company_calendar の fiscal_year 導出と同じ前例） |
| 割当変更履歴 | **v1 見送り + 宿題化**（労務レビュー High の労基法 109 条懸念は実在するが、Phase 0 時点で打刻データが無く改変リスクは Phase 1 以降に実体化。履歴機構を AttendanceHistory と二系統作らない）。NOTES #12 + ROADMAP バックログ「Phase 1-3 AttendanceHistory 設計時に割当履歴も同棲で判断」 |

**0b-4 の範囲外（理由付き）:**
- inactive ユーザーへの割当禁止（実害なし・YAGNI）
- 割当変更履歴（上表の通り宿題化）・締め済み月の編集制限（Phase 3-2 バックログと同根）
- 社員一覧の未割当バッジ列・期限切れ先読み検出（Phase 1 打刻導線 / Phase 4-1 通知基盤へ後送り — ROADMAP バックログ）
- 割当の隙間日の遡及補正（`work_pattern_id IS NULL` レコードへの後追いスナップショット）: Phase 1 の打刻設計事項としてバックログ + NOTES #12-(a)
- **属人的法定制限の割当時警告**（年少者×夜勤パターン: 労基法 61 条 1 項 / flextime×労使協定の対象範囲: 32 条の 3 第 1 項 1 号）: 人×パターンの適法性は割当が結節点だが SPEC §8.8 の v2 扱いに従い**意識的繰延**。SPEC §4.6 へ将来拡張点として逆反映

## 1. スキーマ + 二重防衛

```
create_table :user_work_patterns
  organization_id  bigint  NOT NULL（acts_as_tenant）
  user_id          bigint  NOT NULL
  work_pattern_id  bigint  NOT NULL
  start_date       date    NOT NULL
  end_date         date            （null = 無期限）
  active           boolean NOT NULL default true
```

- **複合 FK**（manager_id と同じ自己参照テナント強制パターン）: `[organization_id, user_id] → users[organization_id, id]` / `[organization_id, work_pattern_id] → work_patterns[organization_id, id]` — クロステナント割当を DB 層で構造的に遮断
- `[organization_id, id]` unique index（プロジェクト規約。被参照予定は現状なし — 規約準拠のためと明記し、将来削る判断材料を残す）
- **btree_gist 拡張 + exclusion constraint**:
  ```sql
  EXCLUDE USING gist (
    organization_id WITH =,
    user_id         WITH =,
    daterange(start_date, end_date, '[]') WITH &&
  ) WHERE (active)
  ```
  - `organization_id WITH =` は意味論上不要（user_id がグローバル一意 PK + 複合 FK で単一テナント保証）だが、「複合一意制約に organization_id を必ず含める」規約（SPEC §2.2）と整合させるため含める（コスト無償・テナント分離レビュー反映）
  - `daterange(s, e, '[]')` は `[s, e+1day)` に正規化・`end_date` null は上限無限。`WHERE (active)` で無効割当は対象外（誤登録の作り直しを妨げない）
  - Rails 8.1.3 は `exclusion_constraint`（where:/using: 付き）と `enable_extension "btree_gist"` の schema.rb ダンプを正式サポート — structure.sql 切替不要（activerecord gem ソース確認済み）。dump には PostgreSQL 正規化形（`'[]'::text` キャスト等）が出るため migration 文字列との差分は正常。**計画の完了条件に「`db:schema:load` ラウンドトリップ確認（load → dump 差分ゼロ）」を含める**

## 2. UserWorkPattern モデル

```ruby
acts_as_tenant(:organization)   # 宣言は belongs_to より先頭（check-tenant-scope フック対象外のサブエージェント実装でも必須）
belongs_to :user
belongs_to :work_pattern
scope :effective_on, ->(date) {
  where(active: true).where(start_date: ..date)
                     .where("end_date IS NULL OR end_date >= ?", date)
}  # Phase 1 の打刻時取得・未割当バナーの単一ソース（述語を 2 度書かない）
```

バリデーション:

1. `start_date` presence・`end_date >= start_date`（end_date があるとき）
2. **期間重複**（SPEC §4.6）: 保存後に `active` である create/update すべてで発火（inactive な自身はスキップ — activate 経由の `update(active: true)` も自然に覆われる）。クエリは **DB と同じ式**で意味の二重実装を避ける:
   ```ruby
   ActsAsTenant.without_tenant do
     UserWorkPattern.where(user_id: user_id, active: true).where.not(id: id)
       .where("daterange(start_date, end_date, '[]') && daterange(?, ?, '[]')", start_date, end_date)
   end
   ```
   `without_tenant` ラップ + `user_id` キーは**②型**（user_id は全域一意 PK + 複合 FK が越境を排除 — organization_id 明示不要。mismatched `with_tenant` 文脈でも default scope に隠されず正しく全件見える）。根拠コメントを実装に残す（RAILS_GOTCHAS の①型/②型書き分け規約）。エラー文言に衝突相手の期間を含める
3. **inactive / クロステナント WorkPattern の割当拒否**（fail-closed・manager 検証と同型）: create 時 / `work_pattern_id` 変更時 / active が true になる遷移時に発火。テナントスコープ下では他テナント id の association 解決が **nil になる**ため、`nil = スコープ外も明示エラー`とし、`without_tenant` で引いた実体の `organization_id == self.organization_id` と `active?` を検証。改竄 POST を 422 で止め、複合 FK は最終防衛に退かせる（テナント分離レビュー High 反映）
4. **TOCTOU（exclusion 違反）**: rescue は **`ActiveRecord::ExclusionViolation` に限定**（Rails 8.1 で StatementInvalid から分化済み — 広く取ると無関係な SQL 失敗が「競合しました」に化ける）。create/update は `errors.add(:base, "他の操作と競合しました。再度お試しください")` + 422 再描画（入力保持）、activate はフォームが無いため 303 redirect + alert

モデル冒頭コメントに意味論を明文化: 「`active=false` = 誤登録の論理削除専用。正常な終了・切替は `end_date`。無効化は過去日の所定根拠を消すための操作ではない」

## 3. WorkPattern 無効化ガード（ガード②同型）

`WorkPattern` に validate 追加: `active` が false に変わるとき、

```ruby
ActsAsTenant.without_tenant do
  UserWorkPattern.where(work_pattern_id: id, active: true)
    .where("end_date IS NULL OR end_date >= ?", organization.today)
end
```

が存在したら拒否。

- クエリは **`work_pattern_id` キー + `without_tenant` ラップ**に固定 — 真の脆弱点は without_tenant でなく **mismatched `with_tenant`**（console で他社テナント設定中の操作。default scope が誤テナントを AND して空集合 → ガード素通り）であり、この形なら両文脈で正しい（テナント分離レビュー High 反映）。spec は without_tenant と mismatched with_tenant の**両文脈**で保護を固定
- `today` はレコードの `organization.today`（組織 TZ）— §0 の TZ 契約
- エラー文言: **先頭 3 名 + 「他 N 名」の上限付き列挙**（flash 肥大防止 — 3 視点一致の Low 反映）。例: 「田中太郎、佐藤花子、鈴木一郎 他 2 名に有効な割当が残っています。先に割当を付け替えてください」
- 過去のみの割当（end_date < today）は妨げない
- `Organization#today` 新設: `Time.current.in_time_zone(time_zone).to_date`

## 4. ルーティング・コントローラ・Policy

```ruby
namespace :admin do
  resources :users do
    resources :user_work_patterns, only: %i[new create edit update] do
      member do
        patch :deactivate
        patch :activate
      end
    end
  end
end
```

- `Admin::UserWorkPatternsController < BaseController`
  - `set_user` は **policy_scope 経由 find**（IDOR 一本道）: `policy_scope([:admin, User]).find(params[:user_id])`。割当は `@user.user_work_patterns.find(params[:id])`（user 経由 + テナント default scope の二重絞り → 404）
  - **`Deactivatable` concern は流用しない** — concern の契約は `redirect_to [:admin, record]`（レコード自身の show）+ `record.name` で、show を持たず name も無いネストリソースと不一致。専用実装で `admin_user_path(@user)` へ 303 redirect。意図的非流用の根拠をコメントに残す
  - deactivate/activate とも `record.update(active: ...)` でバリデーションを通す（activate は §2-2/§2-3 の再検証が走る）。activate は §2-4 の rescue も掛ける
- `Admin::UserWorkPatternPolicy < MasterPolicy`（0b-3 CompanyCalendarPolicy が import ありでも継承した前例に従う）。**「index/show ルート無し・基底定義は未到達」の判断コメントを 0b-3 同型で残す**。Scope は MasterPolicy 継承の `organization_id` 明示二重防衛
- permit は `work_pattern_id / start_date / end_date` のみ — `user_id` は URL（ネスト）から、`active` はメンバーアクション専用（改竄代入経路を閉じる §3.6(2)）

## 5. ビュー

- `admin/users/show` に割当セクション追加: **start_date 降順の単一リスト + 状態バッジ**（有効 / 未来 / 過去 / 無効 — 区分別 4 リストはプレゼン過剰のため不採用・YAGNI 反映）。判定は `organization.today` 基準。過去・無効行は淡色 + 編集導線維持
- **未割当バナー**（社員詳細のみ）: `@user.user_work_patterns.effective_on(@user.organization.today)` が空のとき「現在有効な勤務パターン割当がありません。割当が無い日は労働時間の自動計算・判定ができません（打刻自体は妨げられません）」
- `_form`:
  - WorkPattern select は **`policy_scope([:admin, WorkPattern]).where(active: true)`**（生 where 禁止 — §3.4。0b-1 の users/_form と同前例）
  - **edit 時のみ、現在参照中の無効パターンを「（無効）」ラベル付きで選択肢に含める**（§3 ガードは過去のみ割当のパターン無効化を許すため「無効パターンを参照する過去割当」は正規に存在する。選択肢から消すと保存時に無言で書き換わる — Pragma Mid 反映。§2-3 は「変更時」のみ拒否なので現在値の維持は valid）
  - end_date 空欄 = 無期限のヒント + 「パターン切替は旧割当の終了日設定 → 新規割当の順」の手順ヒント
- 削除 UI なし（無効化のみ）。deactivate ボタンの confirm に「誤登録の取り消し専用。終了・切替は終了日で行ってください」

## 6. テスト（/gen-spec 規約）

**model（user_work_pattern）:**
- 重複マトリクス: 包含 / 部分交差 / 隣接（6/30 と 7/1）は OK / 同日境界は拒否 / 無期限×無期限 / 無期限×有限 / `active=false` の行とは不問 / 他ユーザーとは不問 / 自分自身は除外（update）
- 発火条件: activate 経由（`update(active: true)`）でも重複拒否 + 衝突相手期間入り文言が出ること
- 日付順序・start_date presence
- inactive パターン拒否 3 経路（create / work_pattern_id 変更 / 再有効化）+ **クロステナント work_pattern_id は nil 解決でも明示エラー**（fail-closed）+ 既存割当の無関係カラム更新ではパターン再チェックしない（過去割当の編集が壊れない）
- exclusion constraint の素通り検証: バリデーション skip（`save(validate: false)`）で `ActiveRecord::ExclusionViolation`。**mismatched `with_tenant` 文脈の INSERT でも DB 層が遮断する**ケースを含める
- `effective_on` scope: 境界（start 当日 / end 当日 / 無期限 / inactive 除外）

**model（work_pattern 追補）:**
- ガード 4 象限: 今日以降有効な割当あり → 拒否 / 過去のみ → 許可 / 割当なし → 許可 / inactive 割当のみ → 許可
- 文言: 先頭 3 名 + 「他 N 名」（4 名以上で省略形）
- **without_tenant と mismatched with_tenant の両文脈で保護**されること

**model（organization 追補）:** `#today` が組織 TZ の当日を返す（UTC 日付と割れる時刻帯で assert）

**policy:** hr_admin 許可 / manager・employee 全拒否。Scope の organization_id 絞り

**request:**
- CRUD + deactivate/activate（非 hr_admin 403 ↔ hr_admin 200 の対照ペア・IDOR 404（user_id / id 両方の他テナント値）・書込 303・失敗 422）
- exclusion 競合の 422 再描画（create/update）と activate の 303 + alert

**seeds:** 田中太郎へ標準勤務を無期限割当等（冪等・既存 seed 構造に追記）

## 7. ドキュメント逆反映（PR 同梱）

- **SPEC §4.6**: ①重複防衛は「モデルバリデーション + exclusion constraint の二重」へ更新 ②無効化のみ運用と active/end_date の意味論 ③WorkPattern 無効化ガード ④「今日」は組織 TZ ⑤将来拡張点（属人的法定制限の割当時警告 = v2・61 条/32 条の 3）
- **LABOR_LAW_REVIEW_NOTES #12**: (a) 無割当日の打刻の暫定計算基準と遡及補正の許容範囲 (b) 割当履歴の労基法 109 条該当性と保存期間（5 年・経過措置 143 条は原典未照合） (c) フレックス協定の対象労働者範囲と割当の突合方法
- **ROADMAP**: 0b-4 行チェック + PR 番号。バックログ追加 3 件 — 社員一覧の未割当バッジ + 期限切れ先読み（Phase 1/4-1）・割当隙間日の遡及補正（Phase 1 打刻設計）・割当変更履歴（Phase 1-3 AttendanceHistory 設計時に同棲判断）
- **RAILS_GOTCHAS**: 実装中に新しい罠を踏んだら同 PR で追記（例: exclusion constraint の schema dump 形・ExclusionViolation の rescue 階層）

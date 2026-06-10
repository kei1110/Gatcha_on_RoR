# ブランチ戦略 設計仕様（Gatcha on RoR）

- 日付: 2026-06-10
- 対象リポジトリ: `Gatcha_on_RoR`（Rails 8 マルチテナント SaaS・勤怠ドメイン）
- ステータス: 承認済み（実装計画へ移行予定）

## 0. 前提と決定事項

ブランチ戦略は以下の三つの座標で確定した。

| 座標 | 決定 |
|---|---|
| 開発体制 | **完全に単独**（kei1110・当面ひとり。レビューは自己＋AI が中心） |
| デプロイ形態 | **継続デプロイ**（`main` → 本番） |
| マージ規律 | **PR 必須**（`main` 保護・直 push 禁止） |

この三条件から、採用モデルは **GitHub Flow の厳格運用**で一意に定まる。

### 検討した代替案と却下理由

- **トランクベース（PR 任意）**: `main` 直 commit 中心。「PR 必須」を選んだため却下。
- **Git Flow / 環境ブランチ（develop・release・hotfix・staging/production）**: 単独・継続デプロイには過剰。`develop` と `main` の二重管理が純粋な負債となり、ひとり運用では必ず形骸化する。最大の罠として明示的に退ける。

## 1. 基本モデル — GitHub Flow

- `main` は**常にデプロイ可能**な唯一の長命ブランチ。保護対象・直 push 禁止。
- 全作業は `main` から切る**短命な feature ブランチ**で行う。
- マージ後に CI を通して継続デプロイ。

## 2. ブランチ命名規則 — `type/説明`（kebab-case）

- `type` は Conventional Commits と揃える：
  `feat` / `fix` / `chore` / `docs` / `refactor` / `test` / `perf`（必要に応じ `ci` / `build`）。
- 説明部は kebab-case の簡潔な要約。
- 例：
  - `feat/timecard-aasm`
  - `fix/tenant-scope-leak`
  - `docs/spec-overtime`
  - `chore/ci-setup`
- **SPEC §15 の Phase はブランチ名に埋めない**。Phase は「小さな PR の連なり」として進め、長命な Phase ブランチは作らない（drift と巨大 PR を防ぐ）。

## 3. ブランチ寿命と PR 粒度

- 寿命は**数時間〜長くて 2 日**。こまめに `main` へ rebase して乖離を防ぐ。
- **1 PR = 1 論点**。自己レビュー・AI レビューが有効に効く大きさに保つ。

## 4. コミット規約

- 既存どおり **Conventional Commits** を継続（`feat:` `fix:` `docs:` `chore:` …）。
- **Squash マージのため、PR タイトルがそのまま `main` の commit となる** → PR タイトルも Conventional Commits 形式で記述する。
- `guard-git-identity` フックが kei1110 / `github-kei1110` remote 以外の commit/push を中断（既存資産がそのまま活きる）。

## 5. PR ワークフロー

```
main から feat/xxx を切る
   → 実装・commit
   → push 前に /preflight（ローカル CI 等価チェック）
   → PR 作成（早期は Draft 可）
   → CI 実行 ＋ CodeRabbit 自動レビュー
   → 自己レビュー（diff を通読）
   → 緑になったら Squash マージ
   → head ブランチ自動削除（＋ /clean_gone で掃除）
```

## 6. `main` 保護設定（GitHub Ruleset / Branch protection）

有効化する:

- ✅ Require a pull request before merging
- ✅ Require status checks to pass：**自前 CI（RuboCop / Brakeman / RSpec）のチェックのみ required 登録**。CodeRabbit は全 PR を自動レビューするが required にしない（外部サービスの障害・遅延で merge が物理的に塞がるため。2026-06-10 多視点レビューで改訂）
- ✅ Require linear history（merge commit を排除）
- ✅ Require conversation resolution before merging
- ✅ Block direct pushes（bypass 不可。緊急時のみ一時的に解除）
- ✅ リポジトリ設定で **Squash merge のみ有効**（Merge commit / Rebase は無効化）
- ✅ **Automatically delete head branches** を ON

**要求しない:**

- ⛔ **人間の承認数（Required approvals）は要求しない**。
  単独開発では GitHub の仕様上、自分の PR を自分で Approve できず、承認数を必須にすると永久にマージできなくなる。
  ゲートは**ステータスチェック（CI 緑）**で張る。

## 7. ホットフィックス

- **専用ブランチは持たない**。通常の `fix/` ブランチを優先処理するだけ。
- 継続デプロイゆえ、`fix/` が `main` に入れば即本番反映。Git Flow の `hotfix/` 階層は不要。

## 8. リリース／タグ

- 継続デプロイのためタグは**必須ではない**（YAGNI）。
- 将来バージョン管理が必要になれば、Conventional Commits ＋ Squash の資産から `release-please` 等で **CHANGELOG／タグを自動生成**できる素地は既にある。**現時点では実施しない。**

## 9. 段階導入（`rails new` 前の現状を考慮）

CI が未整備の現在を踏まえ、二段で導入する。

### 今すぐ可能

- 本仕様（命名規則・PR 必須・1 PR 1 論点）の文書化と運用開始。
- リポジトリ設定：**Squash merge のみ有効** ＆ **Auto-delete head branches** を ON。
- `main` への直 push を避ける自己規律の開始。

### `rails new` ＋ CI 整備後

- CI ワークフロー（`.github/workflows/`）を追加。
- Branch protection の **required status checks に自前 CI のみ登録**し、機械的に強制（CodeRabbit は non-required の参考レビュー）。

```
注意: 「Require status checks」は "最低 1 回そのチェックが走った実績"
を前提に動く。CI が存在しない今これを必須にすると、チェックが走らず
全 PR が緑にならずロックアウトされる。よって CI 依存の強制は後段に置く。
```

## 10. ツール連携（既存資産）

| ツール | 役割 | タイミング |
|---|---|---|
| `/preflight` | ローカル CI 等価の静的検証 | push 前 |
| CodeRabbit / `/code-review` | AI コードレビュー（参考。required にしない） | PR 上 |
| `/clean_gone` | リモート削除済みローカルブランチの掃除 | マージ後 |
| `guard-git-identity` フック | commit/push の identity・remote を強制 | commit/push 時 |

## 11. 未決・将来検討（YAGNI で現時点は対象外）

- PR テンプレート（`.github/pull_request_template.md`）の要否。
- `feat` 以外に許可する type の追加可否（`ci` / `build` を含めるか）。
- チーム拡大時の Required approvals 復活運用。

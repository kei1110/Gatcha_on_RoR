---
name: spec-check
description: docs/SPEC.md の仕様と Rails 実装の乖離を確認したいときに使う。TRIGGER - Phase 完了時 / リリース候補マージ前 / SPEC.md 更新後に実装の追従を確認したいとき / ユーザーが「spec-check」「仕様整合」「SPEC 準拠」「仕様逸脱」「未実装の洗い出し」に言及。DO NOT TRIGGER - 仕様書自体の編集中 / SPEC に記載のないリファクタ / 10 行未満の trivial 変更。
---

# spec-check — SPEC ↔ Rails 実装 整合性チェック

`docs/SPEC.md`（勤怠ドメインの SSOT）と実装の乖離を体系的に検出する。SF 版 `spec-check` の Rails 移植。

## 設計原則

- **判定せず材料提供** — 差異を列挙し、「要修正」か「後続 Phase 送り」かの最終判断は人に委ねる
- **並列 subagent** で output token を節約（5 観点を同時起動）
- **Phase 別スコープを尊重** — `docs/SPEC.md` §15 のロードマップで未着手の項目は「乖離」ではなく「予定」として報告する

## 手順

5 つの subagent（Explore / general）を**並列**起動し、結果をマージする。

### Agent 1: データモデル照合
`docs/SPEC.md` §4（全モデル・全カラム）↔ `app/models/` + `db/schema.rb`（or `db/migrate/`）
- SPEC にあるが未実装のモデル / カラム、逆に実装のみのもの
- 型・enum 値・NOT NULL・FK（`belongs_to`）・複合 unique index の不一致
- **全ドメインモデルに `acts_as_tenant(:organization)`** があるか（§3.1）
- `validates_uniqueness_to_tenant` の付与漏れ（テナント内一意制約）

### Agent 2: ビジネスロジック照合
`docs/SPEC.md` §6・§7（打刻・休暇・承認・締め・撤回）↔ `app/services/` + `app/models/`
- SPEC の振る舞いが実装されているか / 矛盾がないか
- **AASM 状態遷移**（§13）が SPEC の状態図と一致するか（approval_status / MAS status / AttendanceRecord status）
- TODO / プレースホルダの洗い出し、後続 Phase 項目の識別

### Agent 3: 労務計算照合（本プロジェクト固有・最重要）
`docs/SPEC.md` §5・§8 ↔ `app/calculators/` + `app/services/`（compliance）
- WorkTime / Overtime / DeepNight / LateEarly / LeaveDays calculator のロジックが §5 と一致するか
- 深夜帯境界（22:00:00 は除外）・按分 FLOOR・HALF_UP 丸め・月 60h 超 50%・法定休日 35%・**管理監督者の深夜例外**（§8.3）
- 36 協定（年 360 / 特別 720 / 複数月平均 80 / 月 45h 超年 6 回・§8.2）、有給 5 日義務（§8.6）、インターバル（§8.4）、連続勤務（§8.5）
- ※ **法令引用そのものの正誤**は `/legal-citation-audit` が担当。本 skill は「コード ↔ SPEC」の一致のみ見る

### Agent 4: 認可・テナント照合
`docs/SPEC.md` §3 ↔ `app/policies/` + コントローラ
- 全コントローラ action に Pundit `authorize`、`Scope` で「自分 + 部下」に絞れているか
- `role`（employee / manager / hr_admin）と `exempt_from_overtime`（管理監督者）の分離（§3.3）
- 自己承認防止（§7.3）の実装
- オーナー（`user_id`）と操作者の分離（§3.5）

### Agent 5: ユーザーストーリー網羅性照合（§1.4）
`docs/SPEC.md` §1.4 動線マップ ↔ `config/routes.rb` + `app/controllers/` + `app/views/` + `app/components/`
- §1.4 各行の `起点 route` が routes.rb に実在し、`nav 入口`（`GlobalNavComponent#links` 等）からクリック到達できるか
- 「機能・policy はあるが画面にリンクが無い」「action はあるが nav/画面から到達不能」な**動線断絶**の検出（§1.4 に無い到達不能画面が無いか）
- §1.4 の `状態`（✅/⚠️）が実態と一致するか・空の `起点 route`／欠落 `nav 入口` が無いか
- ※ 個別機能の有無は Agent 1–4 が担当。本観点は「アクターが端から端まで辿れるか」の到達性のみ見る

## 出力フォーマット

```markdown
## データモデル（§4）
- ✅ 一致: X モデル / ❌ 差異: （詳細リスト）

## ビジネスロジック（§6・§7）
### スコープ内の乖離（要修正）
| 重要度 | SPEC § | 問題 |
### 後続 Phase で対応予定（現時点では正しい）
| SPEC § | 内容 | 対応 Phase |

## 労務計算（§5・§8）
| 計算 | SPEC § | 実装 | 判定 |

## 認可・テナント（§3）
| 観点 | 判定 | 該当箇所 |

## ユーザーストーリー網羅性（§1.4）
| Story（アクター×目的） | 到達可能? (✅/⚠️/❌) | 起点 route 実在 | nav 入口 | 欠落点 |
```

## グリーンフィールド時の注意

`app/` がまだ無い段階（`rails new` 前）では「全項目が未実装 = Phase 0–5 で実装予定」と報告されるのが正常。実装が進むにつれ差異検出の価値が出る。

<!-- Last verified: 2026-06-09 -->

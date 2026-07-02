---
name: multi-perspective-review
description: 実装・SPEC・plan・PR を複数の独立した視点からレビューし、単一観点では見落とす盲点を炙り出したいときに使う。TRIGGER - brainstorm 完了直後 / spec→writing-plans 移行前 / 大規模 PR merge 前 / 認可・労務計算・テナント分離に触れる変更のレビュー / ユーザーが「多視点レビュー」「multi-perspective」「観点漏れ」「いろんな角度で見て」に言及。DO NOT TRIGGER - 単一観点の軽微なレビュー（/code-review で十分） / docs のみの変更。
---

# multi-perspective-review — 多視点並列 critique

単一視点のレビュー（`/code-review` 等）を補完し、対象を複数の独立した視点から**同時に**批評する。SF 版の型化を Rails ドメインへ移植。1 視点では見落とす盲点を、視点の多様性で炙り出す。

## 視点

### Default（常時起動）
1. **原則整合** — 設計が `docs/SPEC.md` §2.2 の 6 原則（計算は PORO / 複雑ロジックは Service / 状態は AASM / 認可は Pundit 一元化 / ガバナ回避の記述を持ち込まない / テナント安全を default）に沿うか
2. **実用主義（Pragma）** — 過剰設計でないか、Rails の枠を外れた独自実装をしていないか、保守者が読めるか
3. **YAGNI 懐疑** — 仕様にない先回り実装・使われない抽象・早すぎる一般化を疑う

### Conditional（対象に応じて追加）
4. **セキュリティ** — auth（Devise）/ 認可（Pundit：全 action `authorize`・Scope）/ テナント分離（`acts_as_tenant`・クロステナント FK 無）/ mass-assignment / 強パラメータ。diff に controller・policy・model を含む時
5. **テスト網羅** — 偽テスト（素通り）・負例欠如・calculator のエッジケース漏れ。diff に `spec/` を含む時
6. **労務法令正確性** — §5 / §8 の計算・閾値が法令と一致するか（必要に応じ `/legal-citation-audit` と連携）。diff に `calculators/` `compliance` を含む時
7. **tx atomicity・状態機械** — 遷移・随伴列の整合・tx 境界/rollback 伝播・副作用順序。対象に enum 値追加・検証追加・AASM・ApplyApproval を含む時（approval-engine-reviewer を lens として起用可 — 4-2 接ぎ目レビューで dormant バグ L1 を独立発見した実績・PR #29）

## 手順

1. **scope 確定** — 引数（PR 番号 / パス / "spec" / "plan"）or `git diff`
2. **視点選定** — Default 3 + 条件付き（diff 内容で自動判定）
3. **並列 critique** — 各視点を独立した subagent で起動。**互いの結論を見せない**（多様性を担保し、追従バイアスを防ぐ）。各 subagent には対象と当該視点のレンズのみ与える。**事実主張の原典検証を義務化**: 対象文書の事実主張（「既存」「終端」「実在する」等の SPEC・実コード参照）は原典/実コードで検証させ、各指摘に **Confirmed（実コードで確認済）/ Plausible（要追検証）** を明記させる — 内在論理だけの批評は設計の誤前提を素通しする（4-2 1st pass が §10⑫「単方向終端」を素通し・検証を義務化した 2nd pass が検出＝PR #29。DEVELOPMENT_WORKFLOW「実挙動検証の義務」の設計レビュー版）
4. **統合報告** — 視点横断の table にマージ。**視点間相互作用検査を一巡**: 視点 A の推奨が視点 B（または既存設計）の担保する不変条件を壊さないかを確認してから採用/binding 化する — 発見は並列・整合は直列（4-2 2nd pass で tx 視点の「notified_on 先行」推奨が労務視点の担保 §10⑤ 猶予アンカーと衝突・統合時未検査のまま binding 化され自己レビューで訂正＝PR #29）

## 接ぎ目モード（seam — DEVELOPMENT_WORKFLOW「接ぎ目レビュー」から呼ばれる変種）

データ層スライス merge 後・次スライス writing-plans 前に、設計 + **merge 済み実装** + その依存/被依存コード（既存 writer・後続 consumer）を対象化する。発動判定（risk gate 3 条件）は DEVELOPMENT_WORKFLOW が正。通常モードとの差分:

- 各視点に **(A) 設計そのものの欠陥 (B) merge 済み実装が既存/後続コードに仕込んだ罠** の両面を課す（対象範囲を dispatch prompt に明記。手順 3 の原典検証義務はそのまま適用）
- 視点は Default 3 固定でなく **touch 面から 3±1 を導出**（検証/enum 値の追加があれば視点 7 必須）
- 畳み方: 通常の統合報告に加え、設計書へ **§binding 追補**（後続 writing-plans の必須要件化）+ RAILS_GOTCHAS 還流 + ROADMAP へ **merge-block 条件付き申し送り**（初出実測 = 4-2 §11・PR #29）

## 出力フォーマット

```markdown
## 視点間で一致した重大指摘（最優先）
- ...

## 統合 critique
| 視点 | 重要度 | 指摘 | 該当箇所 | 推奨 |
|------|--------|------|----------|------|
```

## 設計原則

- **判定せず材料提供** — critique は判断材料。採否は人 / controller agent が決める
- 既存の単一視点レビュー（`/code-review`・CodeRabbit）と**相補的**。本 skill は「広く浅く多角的に」、`/code-review` は「狭く深く」

<!-- Last verified: 2026-07-02（4-2 2nd pass の実測で手順 3/4 を強化・PR #29） -->

---
name: legal-citation-audit
description: SPEC やコードの労働法令引用（労基法・労安法・36 協定の条番号・数値・割増率・各種上限）が原典と一致するか確かめたいときに使う。TRIGGER - SPEC の法令記述を追加/改訂時 / calculator・compliance の実装・レビュー前 / ユーザーが「法令照合」「条文確認」「労基法 根拠」「原典確認」「cite audit」に言及。DO NOT TRIGGER - 法令に無関係な UI/設定変更 / 既存の法令引用に変更のない PR。
---

# legal-citation-audit — 労働法令の原典照合

SPEC・コードの法令引用を、`jp-labor-evidence` MCP（法令原典・行政通達）に当てて検証する。SF 版 `cite-audit`（docs 内部の cite 整合検査）を、**外部の法令原典への照合**へ昇華したもの。本プロジェクト固有の品質保証であり、SF 版には不可能だった一手。

## 前提

- `.mcp.json` の **`jp-labor-evidence` MCP** が稼働（Node/npx・前提なし）
- 利用ツール: `resolve_law` / `get_article` / `search_law` / `get_evidence_bundle` / `diff_revision` / `search_mhlw_tsutatsu` / `get_mhlw_tsutatsu` / `search_jaish_tsutatsu` / `get_jaish_tsutatsu`

## 手順

### Phase 0: 引用の抽出
対象（既定: `docs/SPEC.md`、引数で scope 指定可）から法令引用を抽出する:
- **条番号** — 労基法 32/34/36/37/39/41/61/66/108/109 条、労安法 66 条の 8、施行規則 等
- **数値要件** — 休憩 45/60 分（34 条）、割増 25/35/50%（37 条）、深夜 22:00–05:00、月 60h、年 360/720h、複数月平均 80h、月 45h 超年 6 回、有給 5 日（39 条 7 項）、インターバル 11h、連続勤務 13 日、保持 5 年（109 条）
- **判例参照** — 最高裁 H21.12.18 ことぶき事件（管理監督者の深夜割増・§8.3）等

### Phase 1: 原典照合（MCP）
各引用について `jp-labor-evidence` MCP で:
- `get_article` / `resolve_law` で条文原文を取得し、SPEC の記述（条番号・要件・数値）と突合
- `get_evidence_bundle` でソース URL・監査メタデータを取得し、報告に添付
- 通達依存の解釈（有給 5 日義務の「繰越含む 10 日」判定など・§8.6）は `search_mhlw_tsutatsu` で裏取り
- `diff_revision` で改正（2027–2028 施行予定の勤務間インターバル義務化・連続勤務上限）の現行 / 将来を確認

### Phase 2: 報告

```markdown
| 引用箇所（SPEC §） | 主張 | 原典（条/通達） | 判定 | ソース URL | 備考 |
|---|---|---|---|---|---|
```
- **✅ 一致** / **⚠️ 要確認**（解釈・通達依存、社労士確認推奨）/ **❌ 不一致**（条番号・数値の誤り）
- 改正前後で変わる項目は「現行 / 施行予定」を明示

## 設計原則

- **判定せず材料提供** — MCP の原典とソース URL を併記し、最終判断は人に委ねる。法的判断を要する箇所は「社労士確認推奨」と明示する
- **スコープの分離** — 「コード ↔ SPEC」の一致は `/spec-check`、本 skill は「**SPEC ↔ 法律**」の一致を見る（両者は直交）。本 skill は**引用の点検に絞った軽量インライン照合**であり、§8 の法定値定数化・判定ロジック・除外分岐まで含む総合レビューは `labor-law-compliance-reviewer` agent（subagent dispatch）が担う

<!-- Last verified: 2026-06-09 -->

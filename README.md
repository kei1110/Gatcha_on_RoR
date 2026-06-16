# Gatcha on RoR

日本の労働基準法・労働安全衛生法に準拠した**マルチテナント型勤怠管理 SaaS**。
Salesforce 2GP 勤怠パッケージ「Gatcha」を Ruby on Rails 8 で再設計するプロジェクト（勤怠ドメインのみ。工数管理は範囲外）。

## 目指すプロダクト

単なる打刻記録ではなく、**労働法令違反の予防装置**。複数企業（テナント）が 1 つの Rails アプリを共有し、各社の社員が打刻・休暇申請を行い、管理者が承認・締め・コンプライアンス監視を行う。

- **正確な割増賃金の根拠データ** — 法定残業 / 所定外残業の二系統集計、月 60 時間超 50%・深夜 25%・法定休日 35% の複合割増を漏れなく算出
- **法的義務の番人** — 有給 5 日取得義務・36 協定上限・勤務間インターバル・連続勤務上限・産業医面談を監視（法定基準は定数でテナント改変不可）
- **完全な監査証跡** — 追記専用ログ `AttendanceHistory` で任意時点の勤怠状態を再現。労基署調査・5 年保持義務に対応

主要機能の全体像は [docs/SPEC.md](docs/SPEC.md) §1 を参照。

## 技術スタック

| 層 | 採用技術 |
|----|---------|
| 言語 / FW | Ruby 3.3.11 / Rails 8（モノリス） |
| データベース | PostgreSQL 18 |
| マルチテナント | acts_as_tenant（行レベル分離・`require_tenant = true`） |
| 認証 / 認可 | Devise / Pundit |
| フロントエンド | Hotwire（Turbo + Stimulus）+ ViewComponent + Tailwind CSS |
| リアルタイム | SolidCable + Turbo Streams |
| ジョブ / キャッシュ | SolidQueue（recurring バッチ）/ SolidCache |
| 状態機械 | AASM（申請承認・月次締め） |
| テスト | RSpec + FactoryBot + Capybara + pundit-matchers |

設計原則（計算ロジックは AR 非依存の PORO へ、副作用は Service Object へ）は [docs/SPEC.md](docs/SPEC.md) §2 を参照。

## 開発環境のセットアップ

```bash
# 前提: rbenv で Ruby 3.3.11（.ruby-version で固定）
#       PostgreSQL 18（brew services start postgresql@18）
#       psql は keg-only → PATH に /opt/homebrew/opt/postgresql@18/bin

bin/setup        # 依存インストール + DB 作成
bin/dev          # 開発サーバー起動（rails server + tailwindcss:watch）
```

### rails console の注意

`require_tenant = true` のため、テナントを設定しないとスコープ付きモデルのクエリが `NoTenantSet` で失敗する:

```ruby
ActsAsTenant.current_tenant = Organization.find_by!(subdomain: "acme")
```

## テスト・静的検査

```bash
bundle exec rspec        # テスト
bundle exec rubocop      # lint（rubocop-rails-omakase）
bin/brakeman --no-pager  # セキュリティ静的解析
bin/ci                   # CI 等価の一括実行
```

## ドキュメント

| ドキュメント | 役割 |
|----|----|
| [docs/SPEC.md](docs/SPEC.md) | 仕様の single source of truth |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 進行管理の SSOT（現在地・フェーズ→スライス分解） |
| [docs/RAILS_GOTCHAS.md](docs/RAILS_GOTCHAS.md) | 実際に踏んだ罠の台帳 |
| [docs/LABOR_LAW_REVIEW_NOTES.md](docs/LABOR_LAW_REVIEW_NOTES.md) | 社労士確認事項 |

## 開発状況

開発中（Phase 0b: マスタ CRUD）。現在地と次の一歩は [docs/ROADMAP.md](docs/ROADMAP.md) が正。

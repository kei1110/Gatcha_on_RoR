# frozen_string_literal: true

source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# 追記専用テーブルのトリガー/関数を schema.rb にダンプし、テスト DB に再現する（SPEC §4.14）
gem "fx", "~> 0.11.0" # 0.x は minor bump で破壊変更があり得るため patch レベルに悲観固定
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Multitenancy at the row level
gem "acts_as_tenant"

# Authentication（protected API・内部オーバーライド依存があるため悲観固定。メジャーアップは system spec を通してから）
gem "devise", "~> 5.0"

# 標準文言の日本語化（AR エラー・日付等 / devise flash）。手書き ja.yml は attributes 最小（0b-2 設計 §5）
gem "rails-i18n", "~> 8.0"
gem "devise-i18n", "~> 1.15"

# Authorization
gem "pundit"

# State machine for approval workflow (Phase 2-1)
gem "aasm"

# Ruby 3.4 で標準添付から外れる時限への先回り（0b-3 設計 §1）
gem "csv", "~> 3.3"
# Ruby 4.0 で標準添付から外れた cgi への先回り（本 app は未使用だが将来の依存追加への保険・rails/rails#56457）
gem "cgi", "~> 0.5"

# UI 部品（SPEC §2.1。Admin タブナビが初出。devise と同じ悲観固定方針）
gem "view_component", "~> 4.15"

# Active Storage の variant 用 gem（image_processing / ruby-vips）は 8.1.3.1 で外した。
# CVE-2026-66066 の修正が variant processing を boot 時に解決するようになり、
# `require: false` による libvips の遅延ロード前提が崩れて起動不能になったため。
# 添付（has_one_attached 等）も variant 利用も現時点で 0 件ゆえ削除で解決する。
# variant を使い始める PR で戻すこと（そのとき libvips の段取り＝ローカル brew / CI apt も要る）。

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  gem "rspec-rails"
  gem "factory_bot_rails"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  gem "capybara"
  gem "pundit-matchers"
end

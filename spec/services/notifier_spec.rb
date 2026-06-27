# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifier, type: :service do
  include ActiveJob::TestHelper

  let(:org) { create(:organization, subdomain: "acme") }
  let(:target) { ActsAsTenant.with_tenant(org) { create(:user, email_enabled: false) } }

  def call(**overrides)
    ActsAsTenant.with_tenant(org) do
      described_class.call(**{ target_user: target, title: "承認されました", body: "本文",
                              priority: :informational, source_type: :request_approved }.merge(overrides))
    end
  end

  # 平日昼 JST に固定（quiet/holiday 非抑制）。holiday_block も既定 true ゆえ平日を担保。
  around do |ex|
    travel_to(Time.utc(2026, 6, 24, 3, 0)) { ex.run } # 2026-06-24(水) 12:00 JST
  end

  describe "in_app（常時・優先度/opt-in 非依存）" do
    it "Notification を必ず作成する" do
      expect { call(priority: :reference) }.to change { ActsAsTenant.with_tenant(org) { Notification.count } }.by(1)
    end

    it "target_user の署名 stream に broadcast する（§9⑨）" do
      # turbo-rails の broadcast_prepend_to は stream_name_from = 生 GID param へ直接 broadcast する。
      # ActionCable の broadcasting_for（チャンネル名プレフィックス付き）とは別経路のため、
      # from_channel を使わず raw stream 名で照合する（Rails 実挙動起因の微修正）。
      # prepend + replace で 2 件 broadcast するため at_least(:once) で照合する。
      expect { call }.to have_broadcasted_to(target.to_gid_param).at_least(:once)
    end

    it "未読件数バッジを署名 stream に replace broadcast する（§9⑨）" do
      # turbo-rails は broadcast を raw HTML 文字列として送出する（hash ではない）。
      # have_broadcasted_to.with は「少なくとも 1 件が条件を満たす」照合のため
      # a_string_including で replace ターゲット ID の存在を確認する。
      expect { call }.to have_broadcasted_to(target.to_gid_param)
        .with(a_string_including("notification_bell_count"))
    end
  end

  describe "優先度 × 二重 opt-in（§4.1）" do
    def email_deliveries
      ActsAsTenant.with_tenant(org) { NotificationDelivery.email.count }
    end

    it "action_required は全 opt-in off でも email Delivery 生成（常時）" do
      ActsAsTenant.with_tenant(org) { org.setting.update!(email_notification_enabled: false) }
      expect { call(priority: :action_required) }.to change { email_deliveries }.by(1)
    end

    it "informational・組織 on × 個人 off → email 無" do
      ActsAsTenant.with_tenant(org) do
        org.setting.update!(email_notification_enabled: true)
        target.update!(email_enabled: false)
      end
      expect { call(priority: :informational) }.not_to change { email_deliveries }
    end

    it "informational・組織 off × 個人 on → email 無" do
      ActsAsTenant.with_tenant(org) do
        org.setting.update!(email_notification_enabled: false)
        target.update!(email_enabled: true)
      end
      expect { call(priority: :informational) }.not_to change { email_deliveries }
    end

    it "informational・両 on → email Delivery 生成 + enqueue" do
      ActsAsTenant.with_tenant(org) do
        org.setting.update!(email_notification_enabled: true)
        target.update!(email_enabled: true)
      end
      expect { call(priority: :informational) }
        .to change { email_deliveries }.by(1)
        .and have_enqueued_job(NotificationEmailJob)
    end

    it "reference は両 opt-in でも email Delivery 0 件" do
      ActsAsTenant.with_tenant(org) do
        org.setting.update!(email_notification_enabled: true)
        target.update!(email_enabled: true)
      end
      expect { call(priority: :reference) }.not_to change { email_deliveries }
    end
  end

  describe "抑制 → scheduled_at（email のみ・§4.2）" do
    before do
      ActsAsTenant.with_tenant(org) do
        org.setting.update!(email_notification_enabled: true, holiday_block_enabled: false)
        target.update!(email_enabled: true)
      end
    end

    it "非抑制（平日昼）は scheduled_at ≒ 即時" do
      ActsAsTenant.with_tenant(org) do
        described_class.call(target_user: target, title: "t", body: "b",
                             priority: :action_required, source_type: :request_approved)
        delivery = NotificationDelivery.email.last
        expect(delivery.scheduled_at).to be_within(5.seconds).of(Time.current)
      end
    end

    it "quiet 帯（夜間）は scheduled_at が未来（翌朝）にずれる" do
      # ネスト travel_to ブロックは Rails が禁止。非ブロック travel_to で時刻を上書きする
      # （SimpleStubs#stub_object が既存 stub を除去→再設定。outer ensure が復元・Rails 実挙動起因の微修正）。
      travel_to(Time.utc(2026, 6, 24, 11, 0)) # 20:00 JST
      ActsAsTenant.with_tenant(org) do
        described_class.call(target_user: target, title: "t", body: "b",
                             priority: :action_required, source_type: :request_approved)
        delivery = NotificationDelivery.email.last
        expect(delivery.scheduled_at).to be > Time.current
      end
    end

    it "enqueue は wait_until: scheduled_at で行う" do
      # 同上: 非ブロック travel_to で 20:00 JST に上書きする（Rails 実挙動起因の微修正）。
      travel_to(Time.utc(2026, 6, 24, 11, 0)) # 20:00 JST
      ActsAsTenant.with_tenant(org) do
        described_class.call(target_user: target, title: "t", body: "b",
                             priority: :action_required, source_type: :request_approved)
        delivery = NotificationDelivery.email.last
        enqueued = enqueued_jobs.find { |j| j[:job] == NotificationEmailJob }
        # :at は wait_until の epoch float（ActiveJob::TestHelper）。未来に予約されている。
        expect(enqueued[:at]).to be_within(1.second).of(delivery.scheduled_at.to_f)
      end
    end

    it "休日ブロックで抑制され scheduled_at が未来にずれる（§4.2 holiday 配線）" do
      # holiday 配線（resolver day_type→Boolean→SuppressionWindow 注入）を Notifier レベルで exercise。
      # quiet を無効化し holiday 次元だけ分離。当日を休日登録すると next_allowed_at=翌日 0:00（未来）。
      ActsAsTenant.with_tenant(org) do
        org.setting.update!(quiet_hours_enabled: false, holiday_block_enabled: true)
        create(:company_calendar, date: org.today, day_type: :holiday)
        described_class.call(target_user: target, title: "t", body: "b",
                             priority: :action_required, source_type: :request_approved)
        delivery = NotificationDelivery.email.last
        expect(delivery.scheduled_at).to be > Time.current
      end
    end

    it "個人 UserNotificationPreference が組織設定を上書きする（§4.2 フォールバック順）" do
      # 夜間。組織設定は quiet 有効（既定）だが、個人 UNP で quiet 無効 → UNP 優先で非抑制（即時）。
      # resolved_preference が誤って org.setting を使うと未来 scheduled_at になり FAIL する＝判別的。
      ActsAsTenant.with_tenant(org) do
        create(:user_notification_preference, user: target, quiet_hours_enabled: false)
      end
      travel_to(Time.utc(2026, 6, 24, 11, 0)) # 20:00 JST（組織設定単独なら抑制される時刻）
      ActsAsTenant.with_tenant(org) do
        described_class.call(target_user: target, title: "t", body: "b",
                             priority: :action_required, source_type: :request_approved)
        delivery = NotificationDelivery.email.last
        expect(delivery.scheduled_at).to be_within(5.seconds).of(Time.current)
      end
    end
  end
end

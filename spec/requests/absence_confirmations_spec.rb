# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AbsenceConfirmations", type: :request do
  let!(:org) { create(:organization, subdomain: "acme", time_zone: "Asia/Tokyo") }
  let!(:hr)       { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin, name: "人事 花子") } }
  let!(:manager)  { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: hr, name: "上長 一郎") } }
  let!(:sub)      { ActsAsTenant.with_tenant(org) { create(:user, manager: manager, name: "部下 太郎") } }
  let!(:stranger) { ActsAsTenant.with_tenant(org) { create(:user, manager: hr, name: "他部 次郎") } }

  let(:target_date) { Date.new(2026, 5, 1) }   # 金曜 → 翌営業日 5/4(月) 17:00 が猶予期限

  def candidate_for(user, date: target_date, notified: Date.new(2026, 5, 1))
    ActsAsTenant.with_tenant(org) { create(:absence_candidate, user:, target_date: date, notified_on: notified) }
  end

  # 猶予経過後（2026-05-04 17:01 JST = 08:01 UTC）
  def after_grace(&) = travel_to(Time.utc(2026, 5, 4, 8, 1), &)

  def confirm_params(user, dates, reason: "unauthorized", note: nil)
    { user_id: user.id, dates: dates.map(&:to_s), absence_reason: reason, note: }
  end

  describe "GET index" do
    it "manager は部下の候補のみ見える（同一テナント別部下は見えない）" do
      candidate_for(sub)
      candidate_for(stranger)
      sign_in manager

      get absence_confirmations_url(host: tenant_host(org))

      expect(response.body).to include(sub.name)
      expect(response.body).not_to include(stranger.name)
    end

    it "hr_admin は組織全体の候補が見える" do
      candidate_for(sub)
      candidate_for(stranger)
      sign_in hr

      get absence_confirmations_url(host: tenant_host(org))

      expect(response.body).to include(sub.name, stranger.name)
    end

    it "一般社員は 403（role ゲート）" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get absence_confirmations_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)
    end

    it "猶予未経過の候補は確定可能日時を表示し、チェックボックスを無効化する" do
      candidate_for(sub)
      sign_in manager

      travel_to(Time.utc(2026, 5, 4, 7, 59)) { get absence_confirmations_url(host: tenant_host(org)) }

      expect(response.body).to include("2026-05-04 17:00 以降に確定可")
      expect(response.body).to include("disabled")
    end
  end

  describe "POST create（確定）" do
    it "部下の候補を確定し AR(absent) を作る" do
      candidate_for(sub)
      sign_in manager

      after_grace do
        expect { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [ target_date ]) }
          .to change { AttendanceRecord.unscoped.where(status: :absent).count }.by(1)
      end
      expect(response).to have_http_status(:see_other)
      expect(AbsenceCandidate.unscoped.count).to eq(0)
    end

    it "同一テナントの別部下は 404（IDOR variant 1 — Pundit Scope）" do
      candidate_for(stranger)
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(stranger, [ target_date ]) }

      expect(response).to have_http_status(:not_found)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "他テナントの社員は 404（IDOR variant 2 — acts_as_tenant）" do
      other_org = create(:organization, subdomain: "other")
      outsider = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      sign_in hr

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(outsider, [ target_date ]) }

      expect(response).to have_http_status(:not_found)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "候補の無い日付は 422（却下/撤回 LR 日の捏造を塞ぐ・§12⑨）" do
      candidate_for(sub)
      sign_in manager

      after_grace do
        post absence_confirmations_url(host: tenant_host(org)),
             params: confirm_params(sub, [ target_date, Date.new(2026, 4, 30) ])
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "notified_on: nil の候補は 422（§12①）" do
      candidate_for(sub, notified: nil)
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [ target_date ]) }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "猶予期限前は 422（16:59 JST）" do
      candidate_for(sub)
      sign_in manager

      travel_to(Time.utc(2026, 5, 4, 7, 59)) do
        post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [ target_date ])
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "不正な日付文字列は 422（Date.iso8601 の厳格 parse）" do
      candidate_for(sub)
      sign_in manager

      after_grace do
        post absence_confirmations_url(host: tenant_host(org)),
             params: { user_id: sub.id, dates: [ "2026-13-99" ], absence_reason: "unauthorized" }
      end

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "毒入力の absence_reason は 422（部分成功にしない）" do
      candidate_for(sub)
      sign_in manager

      after_grace do
        post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [ target_date ], reason: "bogus")
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "hr_admin は manager_id: nil の社員（自分自身）も確定できる（§12⑧）" do
      candidate_for(hr)
      sign_in hr

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(hr, [ target_date ]) }

      expect(response).to have_http_status(:see_other)
      expect(AttendanceRecord.unscoped.where(user_id: hr.id, status: :absent).count).to eq(1)
    end

    it "manager は hr_admin（自分の上長）の候補を確定できない（404）" do
      candidate_for(hr)
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(hr, [ target_date ]) }

      expect(response).to have_http_status(:not_found)
    end

    it "確定後に本人へ absence_confirmed 通知を 1 件だけ送る（N 日付を 1 件に集約・§6.10 step 5）" do
      d2 = Date.new(2026, 4, 30) # 過去日（travel_to の「今日」は 2026-05-04）
      candidate_for(sub)
      candidate_for(sub, date: d2)
      sign_in manager

      after_grace do
        post absence_confirmations_url(host: tenant_host(org)),
             params: confirm_params(sub, [ target_date, d2 ])
      end

      notifications = Notification.unscoped.where(target_user_id: sub.id, source_type: :absence_confirmed)
      expect(notifications.count).to eq(1)
      expect(notifications.first.priority).to eq("action_required")
      expect(notifications.first.body).to include("計 2 日", "有給休暇")
      expect(notifications.first.body).not_to include("打刻変更") # CCR new_entry は依然拒否（#48）
    end

    it "確定できた日が 0 件なら通知しない（幻通知の防止）" do
      candidate_for(sub)
      ActsAsTenant.with_tenant(org) { create(:attendance_record, user: sub, work_date: target_date, status: :working) }
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [ target_date ]) }

      expect(Notification.unscoped.where(source_type: :absence_confirmed).count).to eq(0)
    end

    it "通知が失敗しても確定は覆らない（§9.5 rescue+log）" do
      candidate_for(sub)
      allow(Notifier).to receive(:call).and_raise(StandardError, "boom")
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [ target_date ]) }

      expect(response).to have_http_status(:see_other)
      expect(AttendanceRecord.unscoped.where(status: :absent).count).to eq(1)
    end

    it "skip 日は flash に併記される" do
      # guard_not_covered!（労務レビュー是正）の追加により、事前に AttendanceRecord を作る setup は
      # tx へ入る前の全件事前拒否（422）に化けるため、per-day skip はガード通過後の
      # 真の並行性（TOCTOU）としてスタブで再現する（spec/services/absences/confirm_spec.rb 同型）
      d2 = Date.new(2026, 4, 30) # 過去日
      candidate_for(sub)
      candidate_for(sub, date: d2)
      allow(AttendanceHistory).to receive(:create!).and_call_original
      allow(AttendanceHistory).to receive(:create!)
        .with(hash_including(event_date: target_date))
        .and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))
      sign_in manager

      after_grace do
        post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [ target_date, d2 ])
      end

      expect(flash[:notice]).to include(target_date.to_s)
      expect(flash[:notice]).to include("スキップ")
    end

    it "既に勤怠記録がある日を含めると 422 になる（新しい正しい挙動・部分書き込みを起こさない）" do
      candidate_for(sub)
      ActsAsTenant.with_tenant(org) { create(:attendance_record, user: sub, work_date: target_date, status: :working) }
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [ target_date ]) }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttendanceRecord.unscoped.where(status: :absent).count).to eq(0)
    end

    it "記録の整合性エラーは 500 でなく 422（管理者に事実と異なる skip flash を出さない）" do
      candidate_for(sub)
      invalid_history = ActsAsTenant.with_tenant(org) { AttendanceHistory.new }
      allow(AttendanceHistory).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid_history))
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [ target_date ]) }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end
  end

  describe "DELETE destroy（却下 dismiss・§11④/§12⑧）" do
    it "manager は部下の候補を却下でき AR は作られない" do
      c = candidate_for(sub)
      sign_in manager

      expect { delete absence_confirmation_url(c, host: tenant_host(org)) }
        .to change { AbsenceCandidate.unscoped.count }.by(-1)

      expect(response).to have_http_status(:see_other)
      expect(AttendanceRecord.unscoped.count).to eq(0)
      expect(AttendanceHistory.unscoped.count).to eq(0) # ephemeral：監査に残さない
    end

    it "却下は猶予期限前でも可（確定と違い不利益処分でない）" do
      c = candidate_for(sub)
      sign_in manager
      travel_to(Time.utc(2026, 5, 1, 1)) { delete absence_confirmation_url(c, host: tenant_host(org)) }
      expect(AbsenceCandidate.unscoped.count).to eq(0)
    end

    it "同一テナント別部下の候補は 404（IDOR）" do
      c = candidate_for(stranger)
      sign_in manager
      delete absence_confirmation_url(c, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(AbsenceCandidate.unscoped.count).to eq(1)
    end

    it "他テナントの候補は 404（IDOR variant 2 — acts_as_tenant）" do
      other_org = create(:organization, subdomain: "other")
      outsider_candidate = ActsAsTenant.with_tenant(other_org) do
        create(:absence_candidate, user: create(:user, organization: other_org),
                                   organization: other_org, target_date: target_date,
                                   notified_on: target_date)
      end
      sign_in hr

      delete absence_confirmation_url(outsider_candidate, host: tenant_host(org))

      expect(response).to have_http_status(:not_found)
      expect(AbsenceCandidate.unscoped.where(id: outsider_candidate.id)).to exist
    end

    it "一般社員は 403" do
      c = candidate_for(sub)
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      delete absence_confirmation_url(c, host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)
    end
  end
end

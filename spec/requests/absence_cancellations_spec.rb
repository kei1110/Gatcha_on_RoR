# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AbsenceCancellations", type: :request do
  include_context "absence roster"

  let(:work_date) { Date.new(2026, 5, 1) }

  def absent_record_for(user)
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date:, status: :absent, absence_reason: :unauthorized)
    end
  end

  def cancel_params(user, note: "誤検知のため取消")
    { user_id: user.id, work_date: work_date.to_s, note: }
  end

  it "manager は部下の確定済み欠勤を取り消せる（AR destroy・履歴・候補再生成）" do
    record = absent_record_for(sub)
    sign_in manager

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub)

    expect(response).to have_http_status(:see_other)
    ActsAsTenant.with_tenant(org) do
      expect(AttendanceRecord.where(id: record.id)).not_to exist
      expect(AttendanceHistory.find_by(event_type: :absence_canceled, user_id: sub.id)).to be_present
      expect(AbsenceCandidate.find_by(user_id: sub.id, target_date: work_date).notified_on).to be_nil
    end
  end

  it "本人へ取消の informational 通知が届く" do
    absent_record_for(sub)
    sign_in manager

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub)

    notification = ActsAsTenant.with_tenant(org) do
      Notification.find_by(source_type: :absence_canceled, target_user_id: sub.id)
    end
    expect(notification).to be_present
    expect(notification.priority).to eq("informational")
  end

  it "取消理由 note が空なら see_other + alert（AR は残る）" do
    record = absent_record_for(sub)
    sign_in manager

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub, note: "")

    expect(response).to have_http_status(:see_other)
    expect(flash[:alert]).to be_present
    ActsAsTenant.with_tenant(org) { expect(AttendanceRecord.where(id: record.id)).to exist }
  end

  it "manager は別部下（同一テナント）の欠勤を取り消せない（roster 起点の IDOR 封鎖）" do
    absent_record_for(stranger)
    sign_in manager

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(stranger)

    expect(response).to have_http_status(:not_found)
  end

  it "一般社員は 403（role ゲート）" do
    absent_record_for(sub)
    employee = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in employee

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub)

    expect(response).to have_http_status(:forbidden)
  end

  it "締め済み月は see_other + alert（AR は残る）" do
    record = absent_record_for(sub)
    ActsAsTenant.with_tenant(org) do
      create(:monthly_attendance_summary, user: sub,
             year_month: AttendancePeriod.containing(organization: org, date: work_date).label,
             status: :finalized)
    end
    sign_in manager

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub)

    expect(response).to have_http_status(:see_other)
    expect(flash[:alert]).to be_present
    ActsAsTenant.with_tenant(org) { expect(AttendanceRecord.where(id: record.id)).to exist }
  end

  it "既に取り消された欠勤は see_other + alert（RecordNotFound を握って再表示）" do
    absent_record_for(sub)
    sign_in manager
    # AR を消しておく（別操作で先に取り消された状況）
    ActsAsTenant.with_tenant(org) { AttendanceRecord.where(user_id: sub.id, work_date:).delete_all }

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub)

    expect(response).to have_http_status(:see_other)
    expect(flash[:alert]).to be_present
  end
end

# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::BulkFinalizeJob, type: :job do
  let(:org) { create(:organization) }

  it "submitted な summary 群を finalized にする" do
    s1, s2 = ActsAsTenant.with_tenant(org) do
      [ create(:monthly_attendance_summary, status: :submitted),
       create(:monthly_attendance_summary, status: :submitted) ]
    end
    described_class.perform_now(organization_id: org.id, summary_ids: [ s1.id, s2.id ])
    expect(s1.reload).to be_finalized
    expect(s2.reload).to be_finalized
  end

  it "submitted 以外は skip（冪等・at-least-once 再実行で壊れない）" do
    agg, sub = ActsAsTenant.with_tenant(org) do
      [ create(:monthly_attendance_summary, status: :aggregating),
       create(:monthly_attendance_summary, status: :submitted) ]
    end
    described_class.perform_now(organization_id: org.id, summary_ids: [ agg.id, sub.id ])
    expect(agg.reload).to be_aggregating
    expect(sub.reload).to be_finalized
  end

  it "他テナントの id が混じっても finalized にしない（with_tenant スコープ遮断）" do
    own = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, status: :submitted) }
    other_org = create(:organization)
    foreign = ActsAsTenant.with_tenant(other_org) { create(:monthly_attendance_summary, status: :submitted) }
    described_class.perform_now(organization_id: org.id, summary_ids: [ own.id, foreign.id ])
    expect(own.reload).to be_finalized
    expect(foreign.reload).to be_submitted # 別テナントは scope 外で触れない
  end

  it "1 件の失敗が他を巻き込まない（隔離）" do
    s1, s2 = ActsAsTenant.with_tenant(org) do
      [ create(:monthly_attendance_summary, status: :submitted),
       create(:monthly_attendance_summary, status: :submitted) ]
    end
    allow(MonthlySummaries::Finalize).to receive(:call).and_call_original
    allow(MonthlySummaries::Finalize).to receive(:call).with(summary: have_attributes(id: s1.id))
      .and_raise(ActiveRecord::RecordInvalid.new(s1))
    described_class.perform_now(organization_id: org.id, summary_ids: [ s1.id, s2.id ])
    expect(s2.reload).to be_finalized # s1 が落ちても s2 は確定
  end
end

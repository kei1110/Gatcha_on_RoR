# frozen_string_literal: true

require "rails_helper"

RSpec.describe HolidayWorkRequests::ApplyApproval do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:requester) { create(:user, organization: org) }
  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:comp) { create(:leave_type, system_type: :compensatory_leave, organization: org) }
  let(:work_date) { Date.new(2026, 6, 7) } # 日曜

  def hwr(**attrs)
    create(:holiday_work_request, organization: org, requester:, compensation_leave_type: comp,
                                  work_date:, approval_status: :approved, **attrs)
  end

  def apply(req) = described_class.call(holiday_work_request: req, acting_user: approver)

  describe "② 代休残高 +1" do
    it "残高行が無ければ作成して granted_days=1（requester 名義・full 属性）" do
      apply(hwr)
      balance = LeaveBalance.find_by(user: requester, leave_type: comp,
                                     fiscal_year: org.fiscal_year_for(work_date))
      expect(balance).to have_attributes(granted_days: 1, used_days: 0, carry_over_days: 0, granted_on: nil)
    end

    it "既存残高に +1" do
      fy = org.fiscal_year_for(work_date)
      create(:leave_balance, organization: org, user: requester, leave_type: comp,
                             fiscal_year: fy, granted_days: 2, granted_on: nil)
      apply(hwr)
      expect(LeaveBalance.find_by(user: requester, leave_type: comp, fiscal_year: fy).granted_days).to eq(2 + 1)
    end

    it "並行 create の RecordNotUnique を savepoint 隔離し granted_days はちょうど +1" do
      req = hwr
      fy = org.fiscal_year_for(work_date)
      # 「並行 create の敗者」の faithful な再現。本サービス lock_or_create_balance の分岐:
      #   ① scope.lock.first が nil（自分は行がまだ見えない＝敗者として create 経路へ）
      #   → ② create! が DB unique index に弾かれ RecordNotUnique（model validation は別 connection の
      #      未 commit を見ないため通過し、INSERT が index で負ける真のレース）
      #   → ③ savepoint だけ rollback（親 with_lock tx は毒されず健全）
      #   → ④ 再 find で勝者行を掴み +1。
      # この①〜④をちょうど一度だけ踏ませ、granted_days が +2 や例外でなくちょうど +1 になることを pin。
      #
      # 勝者行はこの example の最上位 tx 層に作る（サービスの requires_new savepoint の rollback では
      # 消えない＝別 connection で commit 済みの行と同じ可視性）。
      winner = create(:leave_balance, organization: org, user: requester, leave_type: comp,
                                      fiscal_year: fy, granted_days: 0, carry_over_days: 0,
                                      used_days: 0, granted_on: nil)

      # サービスが組む scope（where(...).lock）の first を制御する。① は nil（敗者）、④（再 find）は
      # 勝者行を返す。scope は同じ条件で 2 度組まれるので first を順に返す sequence で表現。
      scope = LeaveBalance.where(user_id: requester.id, leave_type_id: comp.id, fiscal_year: fy).lock
      allow(LeaveBalance).to receive(:where).and_call_original
      allow(LeaveBalance).to receive(:where)
        .with(user_id: requester.id, leave_type_id: comp.id, fiscal_year: fy)
        .and_return(scope)
      allow(scope).to receive(:lock).and_return(scope)
      allow(scope).to receive(:first).and_return(nil, winner) # ①=nil, ④=winner

      # create! は DB unique index 由来の RecordNotUnique を本物として踏ませる（validation 素通りを模す）。
      allow(LeaveBalance).to receive(:create!)
        .and_raise(ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint")

      apply(req)

      # 勝者行（敗者経路の create はされず）に +1 されただけ＝二重 create も二重加算も起きない。
      expect(LeaveBalance.where(user: requester, leave_type: comp).count).to eq(1)
      expect(winner.reload.granted_days).to eq(1)
      expect(LeaveBalance.where(user: requester, leave_type: comp).sum(:granted_days)).to eq(1)
    end
  end

  describe "③ is_holiday_work（双方向・既存 AR のみ）" do
    it "既存 clocked AR があれば is_holiday_work=true" do
      ar = create(:attendance_record, :done, organization: org, user: requester, work_date:)
      apply(hwr)
      expect(ar.reload.is_holiday_work).to be(true)
    end

    it "AR が無ければ新規作成しない（予約は AR を作らない）" do
      expect { apply(hwr) }.not_to change(AttendanceRecord, :count)
    end

    it "計算済 AR を再計算しない・AttendanceHistory を増やさない" do
      ar = create(:attendance_record, :done, organization: org, user: requester, work_date:)
      expect(Clockings::Recalculate).not_to receive(:call)
      expect { apply(hwr) }.not_to change(AttendanceHistory, :count)
      expect { ar.reload }.not_to(change { ar.attributes.slice("actual_work_hours", "is_late") })
    end
  end

  describe "① 承認時の平日性再検証（D4）" do
    it "承認時に平日化していたら ConflictError で balance も AR も巻き戻る" do
      req = hwr
      ar = create(:attendance_record, :done, organization: org, user: requester, work_date:)
      # work_date を平日扱いにするカレンダー登録（承認後の編集を模す）
      create(:company_calendar, organization: org, date: work_date, day_type: :weekday, name: nil)
      # 実運用は Approve の with_lock 内・同一 tx ゆえ、ConflictError raise で承認ごと atomic rollback する。
      # 直接呼び出しの本 spec では外側 tx が無いので tx で包み、その rollback で副作用が巻き戻ることを確かめる。
      expect do
        ActiveRecord::Base.transaction { apply(req) }
      end.to raise_error(Approvals::ConflictError)
      expect(LeaveBalance.where(user: requester, leave_type: comp)).to be_empty
      expect(ar.reload.is_holiday_work).to be(false)
    end
  end
end

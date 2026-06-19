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

    # 1 回目の locked-scope.first だけ nil（TOCTOU の敗者）を返し、以降は本物に委譲する helper。
    # サービスは scope = where(...) を 1 度だけ組み scope.lock.first を 2 回呼ぶため、scope.lock が返す
    # locked relation の first を「1 回目 nil・2 回目以降は実クエリ」に差し替える（where/create!/validation/
    # rescue は stub せず実挙動を走らせる＝real path 証明）。
    def stub_first_lock_miss!(fy)
      real_locked = LeaveBalance.where(user_id: requester.id, leave_type_id: comp.id, fiscal_year: fy).lock
      lookups = 0
      allow_any_instance_of(ActiveRecord::Relation).to receive(:lock).and_wrap_original do |orig, *args|
        relation = orig.call(*args)
        if relation.where_values_hash.slice("user_id", "leave_type_id", "fiscal_year") ==
           { "user_id" => requester.id, "leave_type_id" => comp.id, "fiscal_year" => fy }
          allow(relation).to receive(:first).and_wrap_original do |first_orig, *fa|
            lookups += 1
            lookups == 1 ? nil : real_locked.first # 1 回目 nil（敗者）→ 以降は本物の勝者行
          end
        end
        relation
      end
    end

    it "現実的な create-race（loser が RecordInvalid(:taken)）を savepoint 隔離し granted はちょうど +1" do
      req = hwr
      fy = org.fiscal_year_for(work_date)
      # 現実的な create-race の loser path を**実挙動で**踏ませる（mock で配線を assert するのでなく
      # lock_or_create_balance の本物の create! → 本物の uniqueness validation → 本物の rescue を走らせる）:
      #   ① scope.lock.first が nil（TOCTOU の敗者として create 経路へ）
      #   → ② 本物の create! が uniqueness validation の SELECT で勝者行を先に見て RecordInvalid(:taken)
      #   → ③ savepoint だけ rollback（親 with_lock tx は毒されず健全）→ :taken arm が握って合流
      #   → ④ 再 find で勝者行を掴み +1。granted が +2 でも例外でもなくちょうど winner+1 になることを pin。
      #
      # 勝者行はこの example の最上位 tx 層に**コミット済・可視**で作る（サービスの requires_new
      # savepoint の rollback でも消えない＝別 connection commit 済み行と同じ可視性）。
      winner = create(:leave_balance, organization: org, user: requester, leave_type: comp,
                                      fiscal_year: fy, granted_days: 0, carry_over_days: 0,
                                      used_days: 0, granted_on: nil)
      stub_first_lock_miss!(fy)

      apply(req)

      # 勝者行（敗者経路の create は validation に弾かれ作られない）に +1 されただけ＝二重 create も
      # 二重加算も起きず、benign な race で承認が abort もしない。
      expect(LeaveBalance.where(user: requester, leave_type: comp).count).to eq(1)
      expect(winner.reload.granted_days).to eq(1)
      expect(LeaveBalance.where(user: requester, leave_type: comp).sum(:granted_days)).to eq(1)
    end

    it "真の INSERT レース（RecordNotUnique arm）も savepoint 隔離し granted はちょうど +1" do
      req = hwr
      fy = org.fiscal_year_for(work_date)
      # validation SELECT が勝者行を見落とした狭い sub-window（true INSERT race）を模す。
      # 勝者行は最上位 tx 層にコミット済。1 回目の lock.first は nil（敗者）。
      winner = create(:leave_balance, organization: org, user: requester, leave_type: comp,
                                      fiscal_year: fy, granted_days: 0, carry_over_days: 0,
                                      used_days: 0, granted_on: nil)
      stub_first_lock_miss!(fy)
      # create! を save!(validate: false) に差し替え、INSERT を DB unique index まで到達させて
      # 本物の RecordNotUnique を踏ませる（validation SELECT を見落とした sub-window の忠実再現）。
      allow(LeaveBalance).to receive(:create!).and_wrap_original do |_orig, **kw|
        record = LeaveBalance.new(**kw)
        record.save!(validate: false)
        record
      end

      apply(req)

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
      create(:attendance_record, :done, organization: org, user: requester, work_date:)
      # §5 calculators は is_holiday_work 非依存（D6）・§4.14 taxonomy に holiday-work event 無し。
      # load-bearing な負の pin はこの 2 つ（Recalculate 呼ばず / AttendanceHistory 増やさず）。
      expect(Clockings::Recalculate).not_to receive(:call)
      expect { apply(hwr) }.not_to change(AttendanceHistory, :count)
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

# frozen_string_literal: true

module LeaveRequests
  # 休暇撤回の逆操作（SPEC §7.6・§13.6・2-5 設計 §4.1）。
  # 呼び出し元: LeaveRequest#apply_withdrawal_effects!（Approvals::Approve の with_lock 内・同一 tx）。
  # 内側で rescue しない — raise 伝播で撤回承認ごと atomic rollback。
  # 処理順: ① 残高減算（balance_tracked? のみ・lock!）→ ② 範囲内 leave-status AR を復元/destroy → ③ leave_withdrawn 履歴。
  class Withdraw
    def self.call(leave_request:, acting_user:) = new(leave_request:, acting_user:).call

    def initialize(leave_request:, acting_user:)
      @leave_request = leave_request
      @acting_user = acting_user
    end

    # 同一日を「なお覆っている」他の休暇申請とみなす approval_status（AR の所有者であり得る状態）。
    # applying はまだ AR に反映されていないので含めない。
    LIVE_LEAVE_STATUSES = %w[approved withdrawal_requested].freeze

    def call
      guard_acting_user_same_organization! # with_tenant へ入る前（昇格前）に検証する
      ActsAsTenant.with_tenant(@leave_request.organization) do
        remove_from_balance
        restore_attendance_records
        record_history
      end
      @leave_request
    end

    private

    # `with_tenant(@leave_request.organization)` はテナント文脈を「切り替える」昇格プリミティブであり
    # 境界ではない（docs/RAILS_GOTCHAS.md）。内側では複合 FK も user_must_belong_to_same_organization も
    # organization_id が引数 org 由来で user_id と整合するため越境を検出できない。昇格前の検証が唯一の境界。
    def guard_acting_user_same_organization!
      return if @acting_user.organization_id == @leave_request.organization_id

      raise ArgumentError, "操作者と休暇申請の組織が一致しません"
    end

    # 正方向 add_to_balance と同一述語（paid_leave? || compensatory_leave?）。R2 残高リーク防止
    def remove_from_balance
      return unless @leave_request.leave_type.balance_tracked?

      fiscal_year = @leave_request.organization.fiscal_year_for(@leave_request.start_date)
      balance = LeaveBalance
                .where(user_id: @leave_request.requester_id,
                       leave_type_id: @leave_request.leave_type_id, fiscal_year:)
                .lock.first
      if balance.nil?
        Rails.error.report(StandardError.new("LeaveRequests::Withdraw: balance_tracked type has no balance row at withdrawal"), handled: true)
        return
      end

      new_used = balance.used_days - @leave_request.days_requested
      Rails.error.report(StandardError.new("withdraw underflow: balance would go negative"), handled: true) if new_used.negative?
      balance.update!(used_days: [ new_used, BigDecimal("0") ].max)
    end

    # counted_dates を再計算せず、範囲内で leave-status を持つ AR を直接巻き戻す（R3/R4）。
    #
    # **「範囲内 leave-status AR = この休暇の日」は成り立たない**（4-2c-2 レビュー C1'）。
    # LeaveRequest には同一日重複の検証も DB 制約も無く、同じ日を覆う承認済 LR が複数あり得る
    # （AR は 1 日 1 行・status 単一ゆえ後勝ちで上書きされる）。したがって分岐は 4 段:
    #   ① 他に生きた LR がその日を覆う → **destroy も absent 復元もしない**（その日はなお休暇。destroy すれば
    #      台帳が、absent へ復元すれば承認済の休暇日が「無届欠勤」に化けて賃金控除される）。
    #      ただし AR には撤回された側の status / leave_type_id が残っており、LeaveAggregator が
    #      これを直読して §8.6 の有給 5 日義務を過少に見せる（4-2c-2 approval-engine W1 / labor-law W-f）
    #      → 生存 LR が**ちょうど 1 件**ならその LR の属性へ貼り直す。2 件以上は所有者を決められないので no-op
    #   ② 実打刻がある → working/clocked_out へ戻す（実労働を欠勤として記録しない・CCR #48 解禁への備え）
    #   ③ 未復元の欠勤 conversion がある → absent へ復元（**source で絞らない**。2 件目の LR は
    #      `was_absent=false` ゆえ absence_to_paid を書かず、source 絞りだと自分の履歴が無い＝
    #      「自分が作った AR」と誤推論して destroy し、欠勤が台帳から消える）
    #   ④ それ以外 → この休暇が新規作成した AR ゆえ destroy
    def restore_attendance_records
      AttendanceRecord
        .where(user_id: @leave_request.requester_id,
               work_date: @leave_request.start_date..@leave_request.end_date,
               status: %i[on_leave morning_half afternoon_half])
        .order(:work_date).each do |record|
          # 判定に使う前に FOR UPDATE で掴み直す（4-2c-3a）。branch ④ の destroy! が DELETE 側に
          # なり得るため ApplyApproval と同一規約に揃える。呼び出し元 with_lock 内ゆえ保持される。
          # lock! はロック取得と同時に DB から属性を再読込するので、以降の clock_in/status は最新。
          # work_date 昇順で回すのは ApplyApproval#upsert_attendance_records（counted_dates=日付昇順）と
          # 同一テーブル内のロック取得順を揃えるため（id 昇順の find_each だと id と work_date の相対順序が
          # branch④ destroy+再作成で逆転し循環待ちの余地が残る・設計書 §3.3 の同一テーブル内順序規約）。
          record.lock!
          live_leaves = live_leaves_covering(record.work_date)
          if live_leaves.any?
            handle_covered_by_other_leave(record, live_leaves)
          elsif record.clock_in.present?
            record.update!(status: record.clock_out.present? ? :clocked_out : :working, leave_type_id: nil)
            Clockings::Recalculate.call(record:) if record.clock_out.present?
          elsif (conversion = unrestored_absence_conversion(record.work_date))
            restore_absence(record, conversion)
          else
            record.destroy!
          end
        end
    end

    # 撤回対象**以外**の生きた休暇申請のうち、その日をなお覆っているもの。
    # exists? ではなく実体を返すのは、一意に決まる場合に AR をその LR へ貼り直すため。
    # 2 件だけ引けば「1 件か / 2 件以上か」の判別に足りる（重複 LR は例外ゆえ全件ロードしない）
    def live_leaves_covering(date)
      LeaveRequest
        .where(requester_id: @leave_request.requester_id, approval_status: LIVE_LEAVE_STATUSES)
        .where.not(id: @leave_request.id)
        .where(start_date: ..date).where(end_date: date..)
        .limit(2).to_a
    end

    # 生存 LR が一意なら貼り直し、複数なら現状維持（可視化のみ）
    def handle_covered_by_other_leave(record, live_leaves)
      if live_leaves.one?
        reassign_to_leave(record, live_leaves.first)
      else
        report_covered_by_other_leave(record)
      end
    end

    # AR の帰属（leave_type_id）を生存 LR へ揃える。
    #
    # **status を変えるのは未打刻日に限る**（labor-law レビュー C1）。打刻のある日を全休へ
    # 再分類すると `MonthlySummaries::Aggregate::WORKED_STATUSES` から外れ、打刻列が行に残ったまま
    # その日の実労働が総労働時間・時間外・60h 超の母数から消える。これは分岐②「実打刻がある →
    # 実労働を欠勤として記録しない」と同じ原則であり、しかも本経路は**別の申請を撤回した副作用**
    # として人の判断を経ずに起きるため、承認経路の既知の穴より危険。半休のまま残せば §8.6 は
    # 過少（= 義務残日数を多く見せる安全側）に振れる。
    #
    # status も leave_type_id も既に一致する日は書き込まない — append-only の台帳に
    # 「起きていない貼り直し」を主張する行を恒久に残さないため（レビュー I2）。
    # previous_status は update! の**前**に捕捉する（capture-before-assign・restore_absence 同型）。
    # AR の note は触らない（その日に残る別種の記述を潰さない）。source は撤回された LR ゆえ、
    # note には移動元と移動先の種別を記す（構造化列だけでは leave_type の変化が見えない・レビュー M1）
    def reassign_to_leave(record, surviving)
      new_status = record.clock_in.blank? ? surviving.leave_status.to_s : record.status
      return if record.status == new_status && record.leave_type_id == surviving.leave_type_id

      previous_status = AttendanceRecord.statuses[record.status]
      previous_type_name = record.leave_type&.name || "種別なし"
      record.update!(status: new_status, leave_type_id: surviving.leave_type_id)
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id, actor: @acting_user, source: @leave_request,
        event_type: :leave_reassigned, event_date: record.work_date,
        previous_status: previous_status,
        new_status: AttendanceRecord.statuses[record.status],
        note: "撤回により #{previous_type_name} → #{surviving.leave_type.name}（休暇申請 ##{surviving.id}）へ貼り直し"
      )
    end

    # その日の欠勤 conversion の最終状態（source を問わない）。absence_to_paid が最後なら未復元。
    # absence_restored が後に来ていれば既に欠勤へ戻しており、二重復元しない。
    #
    # 【不変条件・4-2c-3a】ここに absence_canceled を足す必要はない。status: :absent を書く経路は
    #   app/ 全体で 2 つ（Absences::Confirm#confirm_one = AR 不在日に create!／本 restore_absence =
    #   absence_restored を必ず同時記録）だけで、「AR が absent ⟹ {absence_to_paid, absence_restored}
    #   の最新は absence_to_paid ではない」が帰納的に成立する。取消側の guard_still_absent! がこれを使う。
    #   この帰納は ApplyApproval の read-modify-write が原子的であることに依存し、それは 4-2c-3a の行ロックが担保する
    #   （spec: "不変条件: absence_to_paid が最新なら AR は absent ではない"）
    def unrestored_absence_conversion(work_date)
      latest = AttendanceHistory
               .where(user_id: @leave_request.requester_id, event_date: work_date,
                      event_type: %i[absence_to_paid absence_restored])
               .order(:id).last
      latest if latest&.absence_to_paid?
    end

    # 台帳を守るため意図的に no-op。重複 LR 自体が別の設計課題（ROADMAP・社労士確認 #26）ゆえ可視化する
    def report_covered_by_other_leave(record)
      Rails.error.report(
        StandardError.new("LeaveRequests::Withdraw: #{record.work_date} は他の承認済休暇が覆うため AttendanceRecord を変更しない"),
        handled: true
      )
    end

    # 欠勤へ戻す（理由・自由記述は absence_to_paid 履歴が構造化して保持している）。
    # previous_status は update! の**前**に捕捉する（capture-before-assign）
    def restore_absence(record, conversion)
      previous_status = AttendanceRecord.statuses[record.status]
      record.update!(status: :absent, absence_reason: conversion.absence_reason,
                     note: conversion.note, leave_type_id: nil)
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id, actor: @acting_user, source: @leave_request,
        event_type: :absence_restored, event_date: record.work_date,
        previous_status: previous_status,
        new_status: AttendanceRecord.statuses[:absent],
        absence_reason: conversion.absence_reason, note: conversion.note
      )
    end

    def record_history
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id, actor: @acting_user, source: @leave_request,
        event_type: :leave_withdrawn, event_date: @leave_request.start_date
      )
    end
  end
end

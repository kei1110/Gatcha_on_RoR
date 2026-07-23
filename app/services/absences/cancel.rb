# frozen_string_literal: true

module Absences
  # 欠勤確定の取消（SPEC §6.10・§4.14・設計 4-2c-3b §4.1）。
  # Absences::Confirm は 8 ガード（入口）で確定を守るが、確定は賃金控除に直結する不利益記録なのに
  # 出口が無かった。誤確定を是正する唯一の出口として、absent AR を destroy し
  # AttendanceHistory(absence_canceled) を残す。
  #
  # Confirm の 8 ガードのうち ②毒入力・③候補実在・⑤弁明の行使・⑥未通知・⑦猶予は取消では意味が反転
  # するため共有せず別 service にする。ガード順:
  #   ① 操作者の組織（with_tenant 昇格の**前**）→ ② 取消理由 presence → ③ 対象所有
  #   → ④ 締め済み（tx 内・§7-b の限界あり）→ ⑤ ロック後 status 再判定（with_lock 内・絶対に外せない）
  class Cancel
    def self.call(**) = new(**).call

    def initialize(target_user:, record:, note:, actor:)
      @target_user = target_user
      @record = record
      @note = note
      @actor = actor
    end

    def call
      guard_actor_same_organization! # with_tenant へ入る前（昇格前・Confirm/Withdraw 同型）
      ActsAsTenant.with_tenant(organization) do
        guard_note!
        guard_record_belongs_to_target!
        ActiveRecord::Base.transaction do
          guard_closing! # tx 内（判定と write の間に締めが commit する窓を縮める・§7-b で完全には閉じない）
          @record.with_lock do
            # ⑤ を with_lock の内側に置くのが要点。外に置くと読んだ status と削除する行の status が
            #    別物になり得る（事後有給の承認が absent→on_leave を書く窓）。承認済みの有給休暇日を
            #    取消が destroy する事故はこれでのみ防げる（設計 §4.1・§5 の不変条件が支える）
            guard_still_absent!
            previous_reason = @record.absence_reason # capture-before-destroy
            AttendanceHistory.create!(
              user: @target_user, actor: @actor,
              event_type: :absence_canceled, event_date: @record.work_date,
              previous_status: AttendanceRecord.statuses[:absent], new_status: nil,
              absence_reason: previous_reason, note: @note
            )
            @record.destroy!
            # 取消しても「その日が未説明」である事実は変わらない。notified_on:nil で作り直し
            # 日次バッチの猶予再起算に乗せる（ベストエフォート・§7-a の限界あり）
            AbsenceCandidate.create!(user: @target_user, target_date: @record.work_date, notified_on: nil)
          end
        end
      end
      @record
    end

    private

    def organization = @target_user.organization

    # ① with_tenant(@target_user.organization) は文脈を「切り替える」昇格プリミティブで境界ではない。
    #    内側では複合 FK も cross_tenant 検証も越境を検出できない。昇格前の検証が唯一の境界
    def guard_actor_same_organization!
      return if @actor.organization_id == @target_user.organization_id

      raise IneligibleError, "操作者と対象社員の組織が一致しません"
    end

    # ② 取消は賃金控除を消す低頻度・不正の動機がある唯一の出口ゆえ note 必須（D4）
    def guard_note!
      return if @note.present?

      raise IneligibleError, "取消理由を入力してください"
    end

    # ③ 呼び出し元の契約違反（target_user と record の食い違い）を write 前に拒否する（多層防御）
    def guard_record_belongs_to_target!
      return if @record.user_id == @target_user.id

      raise IneligibleError, "対象の勤怠記録が対象社員のものではありません"
    end

    # ④ 締め済み（submitted / finalized）月は取消不可（Confirm ⑧ と対称・§7-b の TOCTOU 限界あり）
    def guard_closing!
      return unless MonthlySummaries::ClosingLock.locked?(user: @target_user, dates: [ @record.work_date ])

      raise ClosingLockedError, "締め済みの月（提出済 / 確定）の欠勤は取り消せません"
    end

    # ⑤ ロック後に status を再判定。事後有給の承認が absent→on_leave を書いた後なら取消を拒否する
    #    （承認済みの休暇日を destroy しない）。設計 §5 の不変条件が「absent なら absence_to_paid は
    #    最新でない」を保証し、Withdraw の復元と衝突しない
    def guard_still_absent!
      return if @record.absent?

      raise IneligibleError, "既に有給休暇へ振り替えられています（欠勤ではありません）"
    end
  end
end

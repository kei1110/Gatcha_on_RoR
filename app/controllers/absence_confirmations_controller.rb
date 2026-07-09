# frozen_string_literal: true

# 欠勤確定（SPEC §6.10・設計 §5 / §11⑥ / §12③⑧）。管理者が欠勤候補を確認し、確定 or 却下する。
# 認可は二層: ① role ゲート（authorize）② 対象ゲート（policy_scope.find → 404）。
# 対象社員を policy_scope(User) 経由で解決することが、**同一テナントの他部下**を塞ぐ唯一の壁（§12③）。
class AbsenceConfirmationsController < ApplicationController
  def index
    authorize :absence_confirmation, :index?
    load_candidates
  end

  # 1 社員 × N 日付の一括確定（§6.10 step 3-5）。日付の権威は候補テーブル（params ではない）
  def create
    authorize :absence_confirmation, :create?
    target = roster.find(params[:user_id])
    dates = parse_dates(params[:dates])
    Absences::Confirm.call(
      target_user: target, dates:,
      candidates: policy_scope(AbsenceCandidate).where(user_id: target.id, target_date: dates),
      absence_reason: params[:absence_reason], note: params[:note], actor: current_user
    )
    redirect_to absence_confirmations_path, status: :see_other, notice: "欠勤を確定しました"
  rescue Date::Error, TypeError
    render_ineligible("日付の指定が正しくありません")
  rescue Absences::IneligibleError, Absences::ClosingLockedError => e
    render_ineligible(e.message)
  end

  # 却下(dismiss)＝候補を削除して一覧から除く（§11④・§12⑧）。監査には残さない（候補は ephemeral）。
  # 不利益処分でないため猶予期限の制約は掛けない
  def destroy
    authorize AbsenceCandidate, :destroy?             # ① role ゲート（一般社員は 403）
    candidate = policy_scope(AbsenceCandidate).find(params[:id]) # ② 対象ゲート（scope 外は 404）
    candidate.destroy!
    redirect_to absence_confirmations_path, status: :see_other, notice: "欠勤候補を却下しました"
  end

  private

  def load_candidates
    @candidates = policy_scope(AbsenceCandidate).includes(:user).order(:user_id, :target_date)
  end

  # policy_scope(User) は top-level UserPolicy 不在で NotDefinedError ゆえ scope class 明示（RAILS_GOTCHAS）
  def roster = policy_scope(User, policy_scope_class: AbsenceConfirmationPolicy::Scope)

  # 厳格 ISO8601。Date.parse は "2026-13-99" 等のゴミを黙認し得る（RAILS_GOTCHAS）
  def parse_dates(raw) = Array(raw).map { |value| Date.iso8601(value.to_s) }

  def render_ineligible(message)
    load_candidates
    flash.now[:alert] = message
    render :index, status: :unprocessable_entity
  end
end

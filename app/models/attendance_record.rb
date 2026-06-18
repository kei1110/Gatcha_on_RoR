# frozen_string_literal: true

class AttendanceRecord < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user
  # optional: 未割当打刻は NULL（SPEC §5.4 — 1-2 が計算スキップ）。
  # work_pattern_id の書き込みはスナップショットサービス（Clockings::ClockIn）限定。
  # 直接代入経路（1-3 代理打刻・2-3 変更承認）を作る場合は UserWorkPattern 同型の
  # fail-closed 検証を追加すること — 複合 FK は最終防衛（1-1 設計 §1）
  belongs_to :work_pattern, optional: true

  # §4.8 列挙順の予約整数。absent: 5 は 4-2 で追加。
  # plain enum は意図的逸脱: AASM 化は 2-2b 完了後に再判断 = D3 で据置確定（SPEC §13 実装注記）。
  enum :status, { working: 0, clocked_out: 1,
                  morning_half: 2, afternoon_half: 3, on_leave: 4 }, validate: true

  # 全休/半休 AR は打刻が無い（休暇承認の副作用が作成・2-2b）。working/clocked_out は従来必須。
  LEAVE_STATUSES = %w[morning_half afternoon_half on_leave].freeze

  # 代理打刻の理由（§6.1）。NULL = 通常打刻。permit する enum ゆえ allow_nil: true で毒入力のみ 422 に
  # （NULL は一覧外だが許容する — validate: true のみだと nil が拒否される）
  enum :proxy_clock_reason,
       { system_failure: 0, unreachable: 1, forgot_punch: 2, other: 3 },
       validate: { allow_nil: true }

  # 退勤対象・出勤ガード・ホーム表示の単一述語源（1-1 設計 §1 — 二度書き禁止）。
  # window = 夜勤の日付跨ぎ退勤を前日レコードに合流させる探索範囲（SPEC §4.8 出勤日統一）。
  # 端なし Range も可（State の stale 探索が使う）。window は Date の Range を渡すこと
  # （Time を渡すと自身のゾーンの日付に縮約され 1 日ズレ得る）
  scope :working_within, ->(window) { where(status: :working, work_date: window) }

  # 計算 8 列（SPEC §4.8・1-2 設計 §1）。書き込みは Clockings::Recalculate 限定 —
  # NULL = 未計算（Recalculate が一括書き込みするため 8 列は一括 NULL / 一括非 NULL が不変条件）。
  # 未計算の除外は必ずこのスコープ経由。is_late 等の boolean を直接 where しないこと —
  # `where(is_late: false)` は SQL 3 値論理で NULL（未計算）行を黙って落とす（1-2 設計 R9）
  scope :calculated, -> { where.not(actual_work_hours: nil) }

  validates :work_date, presence: true
  validates :clock_in, presence: true, unless: :leave_status?
  validates :actual_work_hours, :legal_overtime_hours, :scheduled_overtime_hours,
            :deep_night_hours, :late_minutes, :early_leave_minutes,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  # 同日 uniqueness のモデル検証は意図的に置かない — TOCTOU で race に勝てないため
  # unique index [user_id, work_date] + RecordNotUnique rescue（Clockings::ClockIn）が一次防衛
  validate :clock_out_not_before_clock_in

  private

  def leave_status? = LEAVE_STATUSES.include?(status)

  def clock_out_not_before_clock_in
    return if clock_out.blank? || clock_in.blank? || clock_out >= clock_in

    errors.add(:clock_out, "は出勤時刻以降にしてください")
  end
end

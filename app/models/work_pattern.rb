# frozen_string_literal: true

class WorkPattern < ApplicationRecord
  acts_as_tenant(:organization)

  # 労基法 34 条 1 項の法定値（テナント設定で改変不可・SPEC §4.4/§4.15）。
  # 検証するのは同項の「量的下限」のみ — 「労働時間の途中に」（位置）・2 項（一斉付与）・
  # 3 項（自由利用）はスキーマ上検証不能で対象外。
  # 出典: https://laws.e-gov.go.jp/law/322AC0000000049（原典照合 2026-06-11）
  # 降順必須（first-match 判定 — 順序を入れ替えると 8h 超が 45 分で valid になる）
  LEGAL_BREAK_REQUIREMENTS = [
    { over_hours: 8, min_break_minutes: 60,
      message: "8 時間超の勤務には 60 分以上の休憩が必要です（労基法 34 条）".freeze }.freeze,
    { over_hours: 6, min_break_minutes: 45,
      message: "6 時間超の勤務には 45 分以上の休憩が必要です（労基法 34 条）".freeze }.freeze
  ].freeze # deep freeze — Hash と message 文字列まで凍結（数値 Integer は元来 immutable）

  validates :name, presence: true
  validates_uniqueness_to_tenant :name
  validates :start_time, :end_time, presence: true
  validates :break_minutes, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :standard_work_hours, presence: true,
            numericality: { greater_than: 0, less_than_or_equal_to: 24 }
  validates :morning_half_break_minutes, :afternoon_half_break_minutes,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  validate :break_meets_legal_minimum
  validate :half_day_breaks_meet_legal_minimum
  validate :core_time_required_for_flextime
  validate :times_must_not_invert_without_night_shift
  validate :deactivation_requires_no_current_or_future_assignments,
           if: -> { active_changed? && !active }

  # null → break_minutes/2 のフォールバックを単一ソース化。
  # Phase 1 の WorkTimeCalculator 入力合成（SPEC §5.1 の同一規則）もこのメソッドを参照すること
  def effective_morning_half_break_minutes = morning_half_break_minutes || break_minutes / 2
  def effective_afternoon_half_break_minutes = afternoon_half_break_minutes || break_minutes / 2

  # 同時指定は保存許可・画面で警告バッジ（SPEC §4.4）。優先ルールは 1-2 で確定:
  # WorkTime/Overtime = night_shift 換算（ScheduledWindow）・LateEarly = flextime コア判定
  # （別カラムを読むため矛盾なく共存 — 1-2 設計 §0-2）
  def mode_conflict? = night_shift? && flextime?

  private

  def legal_break_rule_for(hours)
    LEGAL_BREAK_REQUIREMENTS.find { |r| hours > r[:over_hours] }
  end

  def break_meets_legal_minimum
    return if standard_work_hours.blank? || break_minutes.blank?

    rule = legal_break_rule_for(standard_work_hours)
    return if rule.nil? || break_minutes >= rule[:min_break_minutes]

    errors.add(:base, rule[:message])
  end

  # 半休所定 = standard_work_hours / 2（近似 — 実際の午前/午後は休憩位置により非対称になり得るが
  # SPEC §4.4 の定義に従う。45 分閾値に掛かるのは standard > 12h の場合のみ）
  def half_day_breaks_meet_legal_minimum
    return if standard_work_hours.blank? || break_minutes.blank?

    rule = legal_break_rule_for(standard_work_hours / 2)
    return if rule.nil?

    { "午前半休" => effective_morning_half_break_minutes,
      "午後半休" => effective_afternoon_half_break_minutes }.each do |label, minutes|
      next if minutes >= rule[:min_break_minutes]

      errors.add(:base, "#{label}時の休憩（実効 #{minutes} 分）が不足しています — #{rule[:message]}")
    end
  end

  # 補強 1（SPEC §4.4 へ逆反映済み）: §5.4 の遅刻早退判定はコアタイム基準 —
  # コアタイム無しの flextime は Phase 1 で判定不能データになるため書き込み時に止める
  def core_time_required_for_flextime
    return unless flextime?

    if core_time_start.blank? || core_time_end.blank?
      errors.add(:base, "フレックスタイム制にはコアタイムの開始・終了の両方が必要です")
    elsif core_time_start == core_time_end ||
          (!night_shift? && core_time_start > core_time_end)
      # 等値（縮退）は常時拒否。逆転は非夜勤のみ拒否 — 夜勤は日跨ぎコアタイム（例: 23:00-03:00）を許容
      errors.add(:core_time_end, "はコアタイム開始より後の時刻にしてください")
    end
  end

  # 補強 2（SPEC §4.4 へ逆反映済み）: §5.1 の翌日換算は night_shift かつ start > end が前提。
  # 非夜勤の時刻逆転は負の労働時間を生むため拒否。
  # 等値（長さ 0 の勤務帯）は夜勤含め常時拒否 — ScheduledWindow が長さ 0 の窓になる（1-2 設計 R6）
  def times_must_not_invert_without_night_shift
    return if start_time.blank? || end_time.blank?

    if start_time == end_time
      errors.add(:end_time, "は始業時刻と異なる時刻にしてください")
    elsif !night_shift? && start_time > end_time
      errors.add(:end_time, "は始業時刻より後にしてください（日跨ぎ勤務は夜勤フラグを有効にしてください）")
    end
  end

  # 0b-4 設計 §3（User ガード②同型）: 今日以降も有効な割当が残る無効化を拒否し、
  # 「先に割当を付け替え → 無効化」の一本道にする（Phase 1 で無効パターンが打刻に
  # 使われ続ける/計算不能になる二択を構造的に避ける）。
  # ②型クエリ + without_tenant ラップ: 真の脆弱点は mismatched with_tenant
  # （default scope が誤テナントを AND して空集合 → ガード素通り）。work_pattern_id キーは
  # 複合 FK (organization_id, work_pattern_id) が越境を排除するため、スコープ無しでも
  # 自テナントの割当だけが見える。today はレコードの organization から導出
  # （current_tenant 不使用 — company_calendar の fiscal_year 導出と同じ前例）
  def deactivation_requires_no_current_or_future_assignments
    assignments = ActsAsTenant.without_tenant do
      UserWorkPattern.where(work_pattern_id: id, active: true)
                     .where("end_date IS NULL OR end_date >= ?", organization.today)
                     .includes(:user).order(:start_date, :id).to_a
    end
    return if assignments.empty?

    names = assignments.map { |a| a.user.name }.uniq
    shown = names.first(3).join("、")
    rest = names.size - 3
    label = rest.positive? ? "#{shown} 他 #{rest} 名" : shown
    errors.add(:base, "#{label}に有効な割当が残っています。先に割当を付け替えてください")
  end
end

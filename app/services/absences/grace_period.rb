# frozen_string_literal: true

module Absences
  # 欠勤確定の猶予期限（SPEC §6.8「猶予: 翌営業日 17:00」）の単一定義。
  # 確定ガード（Absences::Confirm）・事前通知本文（AttendanceAnomalies::Detect）・確定 UI が
  # 同じ値を共有する（二度書き禁止）。resolver を保持し notified_on ごとにメモ化して
  # 候補 N 件の 30 日レンジクエリ N 回（N+1）を 1 回に畳む。
  #
  # 17:00 は法定値ではなく運用値（SPEC §8 の鉄則: 法定値をテナント設定から読まない — 逆に
  # 本値は運用値ゆえコード内定数で足りる）。TZ は organization.time_zone（地域設定）。
  class GracePeriod
    DEADLINE_HOUR = 17

    def initialize(organization:)
      @organization = organization
      @resolver = CompanyCalendarResolver.new(organization:)
      @cache = {}
    end

    # notified_on の翌営業日 17:00（組織 TZ）。notified_on が nil、または先読み範囲内に
    # 稼働日が無ければ nil（呼び出し側が fail-closed に倒す）
    def deadline(notified_on)
      return nil if notified_on.nil?

      @cache[notified_on] ||= compute_deadline(notified_on)
    end

    # 猶予が経過したか。deadline を算出できない場合は false（未経過＝確定不可の側へ倒す）
    def elapsed?(notified_on, now = Time.current)
      due = deadline(notified_on)
      !due.nil? && now > due
    end

    private

    def compute_deadline(notified_on)
      next_day = @resolver.next_business_day(notified_on)
      return nil if next_day.nil?

      ActiveSupport::TimeZone[@organization.time_zone]
        .local(next_day.year, next_day.month, next_day.day, DEADLINE_HOUR)
    end
  end
end

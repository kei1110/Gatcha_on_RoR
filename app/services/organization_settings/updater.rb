module OrganizationSettings
  # 設定画面アグリゲートの更新（0b-5 設計 §3）: Organization.fiscal_year_end_month +
  # OrganizationSetting を単一 tx で保存し、決算月が変わったときだけ CompanyCalendar の
  # fiscal_year を再計算する。
  #
  # 前提（Pragma レビュー Critical の回避）: organization には ActsAsTenant.current_tenant の
  # インスタンスを渡すこと（controller が固定）。acts_as_tenant は organization_id 一致時に
  # DB を読まず current_tenant を返すため、再計算中の cal.organization も本インスタンス
  # （更新後の月）を見る — 旧値混入と N+1 SELECT が同時に消える。
  # with_tenant で自己完結: console/将来ジョブから呼ばれても自社の行しか触れない（SPEC §3.6）
  class Updater
    Result = Data.define(:success, :recalculated_count, :organization, :setting) do
      def success? = success
    end

    def self.call(organization:, organization_params:, setting_params:)
      new(organization, organization_params, setting_params).call
    end

    def initialize(organization, organization_params, setting_params)
      @organization = organization
      @setting = organization.setting
      @organization_params = organization_params
      @setting_params = setting_params
    end

    def call
      @organization.assign_attributes(@organization_params)
      @setting.assign_attributes(@setting_params)
      # & で両方の valid? を必ず評価する（&& は短絡して 2 モデル目のエラーが集まらない）
      return failure unless @organization.valid? & @setting.valid?

      count = 0
      ActsAsTenant.with_tenant(@organization) do
        ApplicationRecord.transaction do
          @organization.save!
          @setting.save!
          count = recalculate_fiscal_years if @organization.saved_change_to_fiscal_year_end_month?
        end
      end
      Result.new(success: true, recalculated_count: count,
                 organization: @organization, setting: @setting)
    rescue ActiveRecord::RecordInvalid => e
      # 既存カレンダーの再検証失敗で設定更新ごと巻き戻す（500 にしない 422 合流・設計 §3-4）
      @organization.errors.add(
        :base,
        "会社カレンダーの再検証に失敗したため変更を取り消しました: #{e.record.errors.full_messages.join('。')}"
      )
      failure
    end

    private

    # save! を通す（update_all/update_column はバリデーション・コールバックバイパス規約で不採用。
    # CompanyCalendar#set_fiscal_year（before_validation/before_save）が date から再導出する）。
    # 実変更数 = fiscal_year が実際に変わった行のみ（no-op save は UPDATE を発行しない）
    def recalculate_fiscal_years
      count = 0
      @organization.company_calendars.find_each do |calendar|
        calendar.save!
        count += 1 if calendar.saved_changes.key?("fiscal_year")
      end
      count
    end

    def failure
      Result.new(success: false, recalculated_count: 0,
                 organization: @organization, setting: @setting)
    end
  end
end

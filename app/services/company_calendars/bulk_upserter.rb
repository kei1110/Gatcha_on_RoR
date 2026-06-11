module CompanyCalendars
  # 全件検証 → 1 トランザクション upsert の共通コア（CSV インポートと法定休日一括生成が合流 — 0b-3 設計 §3）。
  # upsert_all / insert_all は使用禁止 — acts_as_tenant とモデルバリデーションを両方バイパスする。
  # 性能最適化で移行する場合は organization_id 明示付与 + unique_by: [:organization_id, :date] +
  # 値検証の自前実装が条件（設計 §0 の制約）
  class BulkUpserter
    MAX_ROWS = 2_000 # 同期処理の妥当性ガード（実需は 1 年 366 行・5 年分 1,830 行）
    ATTRIBUTE_KEYS = %i[day_type name counts_as_paid_leave].freeze # assign する 3 列（date は new/find キーとして別扱い）

    Result = Data.define(:errors, :created_count, :updated_count) do
      def success? = errors.empty?
    end

    # organization 明示必須 — without_tenant 文脈（seed・rake・console）で他テナントの
    # 同日行を掴む fail-open をサービス側で遮断（RAILS_GOTCHAS・0b-3 設計 §3）
    def initialize(organization:, allow_demotion: false)
      raise ArgumentError, "organization は必須です" if organization.nil?

      @organization = organization
      @allow_demotion = allow_demotion
    end

    # rows: [{ line:, date:, day_type:, name:, counts_as_paid_leave: }, ...]（date は Date 型）
    # rows 内の日付重複はパーサ（CsvParser）/ ビルダー（LegalHolidayRowsBuilder）が排除済みの前提。
    # 到達した場合も uniqueness バリデーションエラーとして全件不採用に落ちる（部分コミットなし）
    def call(rows)
      return failure("行数が上限 #{MAX_ROWS} を超えています（#{rows.size} 行）") if rows.size > MAX_ROWS

      errors = []
      created = updated = 0
      ActsAsTenant.with_tenant(@organization) do
        ActiveRecord::Base.transaction do
          # 既存行を 1 クエリでプリロード（作成/更新の振り分け + 行単位 find の削減）
          existing = CompanyCalendar.where(date: rows.map { |r| r[:date] }).index_by(&:date)
          rows.each do |row|
            record = existing[row[:date]] || CompanyCalendar.new(date: row[:date])
            if (error = demotion_error(record, row))
              errors << error
              next
            end
            record.assign_attributes(row.slice(*ATTRIBUTE_KEYS))
            if record.save
              record.previously_new_record? ? created += 1 : updated += 1
            else
              errors << RowError.new(line: row[:line], message: record.errors.full_messages.join("。"))
            end
          end
          raise ActiveRecord::Rollback if errors.any?
        end
      end
      return Result.new(errors:, created_count: 0, updated_count: 0) if errors.any?

      Result.new(errors: [], created_count: created, updated_count: updated)
    rescue ActiveRecord::RecordNotUnique
      # 並行インポートの TOCTOU — 500 にせずエラー表示へ（0b-3 設計 §3）
      failure("別のインポートが同時に実行されました。最新の一覧を確認してから再度お試しください")
    end

    private

    # 35% 付け漏れ方向（legal_holiday → 他種別）だけ非対称に守る（SPEC §4.7・0b-3 設計 §3）
    def demotion_error(record, row)
      return if @allow_demotion
      return unless record.persisted? && record.legal_holiday? && row[:day_type].to_s != "legal_holiday"

      RowError.new(line: row[:line],
                   message: "#{record.date} は登録済みの法定休日です。" \
                            "変更するには「法定休日の変更を許可」を有効にしてください")
    end

    def failure(message)
      Result.new(errors: [ RowError.new(line: nil, message:) ], created_count: 0, updated_count: 0)
    end
  end
end

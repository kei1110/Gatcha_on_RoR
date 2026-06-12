require "rails_helper"

RSpec.describe UserWorkPattern, type: :model do
  let(:user)    { create(:user) }
  let(:pattern) { create(:work_pattern) }

  describe "期間重複（SPEC §4.6・0b-4 設計 §2-2）" do
    let!(:existing) do
      create(:user_work_pattern, user: user, work_pattern: pattern,
             start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30))
    end

    def build_overlap(start_date:, end_date: nil)
      build(:user_work_pattern, user: user, work_pattern: pattern,
            start_date: start_date, end_date: end_date)
    end

    it "包含（既存の内側）は拒否" do
      expect(build_overlap(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 31))).not_to be_valid
    end

    it "部分交差（末尾に重なる）は拒否" do
      expect(build_overlap(start_date: Date.new(2026, 6, 30), end_date: Date.new(2026, 12, 31))).not_to be_valid
    end

    it "隣接（既存終了の翌日から）は許可" do
      expect(build_overlap(start_date: Date.new(2026, 7, 1))).to be_valid
    end

    it "無期限の新規が既存に被さるのは拒否" do
      expect(build_overlap(start_date: Date.new(2026, 1, 1))).not_to be_valid
    end

    it "無期限の既存と未来の新規は拒否（end_date NULL = 全未来日と重複扱い・SPEC §4.6）" do
      other = create(:user)
      create(:user_work_pattern, user: other, work_pattern: pattern,
             start_date: Date.new(2026, 1, 1)) # end nil
      dup = build(:user_work_pattern, user: other, work_pattern: pattern,
                  start_date: Date.new(2030, 1, 1))
      expect(dup).not_to be_valid
    end

    it "active=false の既存とは重複可（誤登録の作り直しを妨げない）" do
      existing.update_column(:active, false)
      expect(build_overlap(start_date: Date.new(2026, 5, 1))).to be_valid
    end

    it "他ユーザーの割当とは不問" do
      other = create(:user)
      expect(build(:user_work_pattern, user: other, work_pattern: pattern,
                   start_date: Date.new(2026, 5, 1))).to be_valid
    end

    it "自分自身は除外（update で期間を変えられる）" do
      existing.end_date = Date.new(2026, 5, 31)
      expect(existing).to be_valid
    end

    it "エラー文言に衝突相手の期間を含む" do
      record = build_overlap(start_date: Date.new(2026, 5, 1))
      record.valid?
      expect(record.errors[:base].join).to include("2026-04-01").and include("2026-06-30")
    end

    it "activate 経由（update(active: true)）でも重複拒否 + 衝突相手期間入り文言（0b-4 設計 §2-2 発火条件）" do
      overlapped = create(:user_work_pattern, user: user, work_pattern: pattern,
                          start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 31), active: false)
      expect(overlapped.update(active: true)).to be(false)
      expect(overlapped.errors[:base].join).to include("重複")
    end

    it "mismatched with_tenant 文脈でも重複を検出する（without_tenant ラップの固定・設計 §2-2）" do
      other_org = create(:organization)
      dup = build_overlap(start_date: Date.new(2026, 5, 1))
      ActsAsTenant.with_tenant(other_org) do
        expect(dup).not_to be_valid
      end
    end
  end

  describe "日付" do
    it "start_date 必須" do
      record = build(:user_work_pattern, user: user, work_pattern: pattern, start_date: nil)
      expect(record).not_to be_valid
      expect(record.errors[:start_date]).to be_present
    end

    it "end_date < start_date はバリデーションで拒否（daterange の DB エラーに先回り）" do
      record = build(:user_work_pattern, user: user, work_pattern: pattern,
                     start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 3, 31))
      expect(record).not_to be_valid
      expect(record.errors[:end_date]).to be_present
    end

    it "end_date = start_date（1 日だけの割当）は許可" do
      expect(build(:user_work_pattern, user: user, work_pattern: pattern,
                   start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 4, 1))).to be_valid
    end
  end

  describe "勤務パターン整合（fail-closed・0b-4 設計 §2-3）" do
    it "inactive パターンの新規割当は拒否" do
      retired = create(:work_pattern, active: false)
      record = build(:user_work_pattern, user: user, work_pattern: retired)
      expect(record).not_to be_valid
      expect(record.errors[:work_pattern_id].join).to include("有効な勤務パターン")
    end

    it "パターン変更で inactive を指定すると拒否" do
      record = create(:user_work_pattern, user: user, work_pattern: pattern)
      retired = create(:work_pattern, active: false)
      record.work_pattern_id = retired.id
      expect(record).not_to be_valid
    end

    it "他テナントの work_pattern_id は nil 解決でも明示エラー（改竄 POST を 422 で止める）" do
      other_pattern = ActsAsTenant.with_tenant(create(:organization)) { create(:work_pattern) }
      record = build(:user_work_pattern, user: user)
      record.work_pattern_id = other_pattern.id
      expect(record).not_to be_valid
      expect(record.errors[:work_pattern_id].join).to include("同一組織")
    end

    it "無関係カラムの更新ではパターン再チェックしない（無効パターン参照の過去割当の end_date 編集が通る）" do
      record = create(:user_work_pattern, user: user, work_pattern: pattern,
                      start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31))
      pattern.update_column(:active, false) # ガードを通さず無効化された状態を再現
      record.end_date = Date.new(2026, 2, 28)
      expect(record).to be_valid
    end

    it "再有効化時に inactive パターンなら拒否（active になる遷移で再チェック）" do
      record = create(:user_work_pattern, user: user, work_pattern: pattern, active: false)
      pattern.update_column(:active, false)
      expect(record.update(active: true)).to be(false)
      expect(record.errors[:work_pattern_id]).to be_present
    end
  end

  describe "exclusion constraint（DB 最終防衛・0b-4 設計 §1）" do
    it "バリデーション skip の重複 INSERT は ActiveRecord::ExclusionViolation" do
      create(:user_work_pattern, user: user, work_pattern: pattern,
             start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30))
      dup = build(:user_work_pattern, user: user, work_pattern: pattern,
                  start_date: Date.new(2026, 5, 1))
      expect { dup.save(validate: false) }.to raise_error(ActiveRecord::ExclusionViolation)
    end

    it "inactive 行は constraint の対象外（WHERE active）" do
      create(:user_work_pattern, user: user, work_pattern: pattern,
             start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30), active: false)
      dup = build(:user_work_pattern, user: user, work_pattern: pattern,
                  start_date: Date.new(2026, 5, 1))
      expect { dup.save(validate: false) }.not_to raise_error
    end
  end

  describe ".effective_on（Phase 1 取得述語の単一ソース・0b-4 設計 §2）" do
    let!(:assignment) do
      create(:user_work_pattern, user: user, work_pattern: pattern,
             start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30))
    end

    it "開始当日・終了当日は含む / 範囲外は含まない" do
      expect(described_class.effective_on(Date.new(2026, 4, 1))).to contain_exactly(assignment)
      expect(described_class.effective_on(Date.new(2026, 6, 30))).to contain_exactly(assignment)
      expect(described_class.effective_on(Date.new(2026, 3, 31))).to be_empty
      expect(described_class.effective_on(Date.new(2026, 7, 1))).to be_empty
    end

    it "無期限（end_date NULL）は全未来日で有効" do
      assignment.update!(end_date: nil)
      expect(described_class.effective_on(Date.new(2030, 1, 1))).to contain_exactly(assignment)
    end

    it "inactive は除外" do
      assignment.update_column(:active, false)
      expect(described_class.effective_on(Date.new(2026, 5, 1))).to be_empty
    end
  end
end

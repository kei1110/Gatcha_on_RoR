require "rails_helper"

RSpec.describe WorkPattern, type: :model do
  describe "name（3 点セット・gen-spec 規約）" do
    it "is unique within tenant" do
      create(:work_pattern, name: "日勤")
      expect(build(:work_pattern, name: "日勤")).not_to be_valid
    end

    it "allows same name in another tenant (鏡像)" do
      create(:work_pattern, name: "日勤")
      ActsAsTenant.with_tenant(create(:organization)) do
        expect(build(:work_pattern, name: "日勤")).to be_valid
      end
    end

    it "is enforced by composite unique index at DB level" do
      pattern = create(:work_pattern, name: "日勤")
      dup = build(:work_pattern, name: "日勤", organization: pattern.organization)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "presence / numericality" do
    it "requires name/start/end/break/standard hours" do
      wp = WorkPattern.new
      wp.valid?
      expect(wp.errors[:name]).to be_present
      expect(wp.errors[:start_time]).to be_present
      expect(wp.errors[:end_time]).to be_present
      expect(wp.errors[:break_minutes]).to be_present
      expect(wp.errors[:standard_work_hours]).to be_present
    end

    it "full_message が日本語属性名で組まれる（i18n 効果・ja.yml の手書きキーを踏む）" do
      wp = WorkPattern.new
      wp.valid?
      expect(wp.errors.full_messages).to include("パターン名を入力してください")
    end

    it "rejects negative break / zero hours / over 24h / negative half breaks" do
      expect(build(:work_pattern, break_minutes: -1)).not_to be_valid
      expect(build(:work_pattern, standard_work_hours: 0)).not_to be_valid
      expect(build(:work_pattern, standard_work_hours: 24.5)).not_to be_valid
      expect(build(:work_pattern, morning_half_break_minutes: -1)).not_to be_valid
    end
  end

  describe "法定休憩（労基法 34 条 1 項・境界 6 象限）" do
    def pattern(hours:, brk:)
      build(:work_pattern, standard_work_hours: hours, break_minutes: brk)
    end

    it "6h ちょうどは休憩 0 で valid（『超』判定）" do
      expect(pattern(hours: 6, brk: 0)).to be_valid
    end

    it "6h 超 44 分は invalid（SPEC 文言一致まで assert）" do
      wp = pattern(hours: 6.5, brk: 44)
      expect(wp).not_to be_valid
      expect(wp.errors[:base]).to include("6 時間超の勤務には 45 分以上の休憩が必要です（労基法 34 条）")
    end

    it "6h 超 45 分は valid" do
      expect(pattern(hours: 6.5, brk: 45)).to be_valid
    end

    it "8h ちょうど 45 分は valid" do
      expect(pattern(hours: 8, brk: 45)).to be_valid
    end

    it "8h 超 59 分は invalid（SPEC 文言一致）" do
      wp = pattern(hours: 8.5, brk: 59)
      expect(wp).not_to be_valid
      expect(wp.errors[:base]).to include("8 時間超の勤務には 60 分以上の休憩が必要です（労基法 34 条）")
    end

    it "8h 超 60 分は valid" do
      expect(pattern(hours: 8.5, brk: 60)).to be_valid
    end
  end

  describe "法定休憩（半休側 — standard 13h でしか発火しない点に注意・0b-2 設計 §7）" do
    # 半休所定 = 13/2 = 6.5h > 6h → 45 分必要
    let(:base) { { standard_work_hours: 13, break_minutes: 90 } }

    it "明示 44 分は invalid・45 分は valid（午前）" do
      expect(build(:work_pattern, **base, morning_half_break_minutes: 44)).not_to be_valid
      expect(build(:work_pattern, **base, morning_half_break_minutes: 45)).to be_valid
    end

    it "null は break_minutes/2 の実効値で判定（88→実効 44 invalid / 90→実効 45 valid）" do
      expect(build(:work_pattern, standard_work_hours: 13, break_minutes: 88)).not_to be_valid
      expect(build(:work_pattern, standard_work_hours: 13, break_minutes: 90)).to be_valid
    end

    it "午前のみ invalid のとき午後は独立（エラーは午前側のみ）" do
      wp = build(:work_pattern, **base, morning_half_break_minutes: 10, afternoon_half_break_minutes: 50)
      expect(wp).not_to be_valid
      expect(wp.errors[:base].join).to include("午前半休")
      expect(wp.errors[:base].join).not_to include("午後半休")
    end
  end

  describe "#effective_*_break_minutes（null フォールバックの単一ソース）" do
    it "null なら break_minutes/2・指定があればその値" do
      wp = build(:work_pattern, break_minutes: 60)
      expect(wp.effective_morning_half_break_minutes).to eq(30)
      wp.morning_half_break_minutes = 20
      expect(wp.effective_morning_half_break_minutes).to eq(20)
    end
  end

  describe "フレックスのコアタイム（0b-2 設計 §2 補強 1）" do
    it "flextime なのにコアタイムが無いと invalid" do
      expect(build(:work_pattern, flextime: true)).not_to be_valid
    end

    it "コアタイム逆転（start >= end）は invalid" do
      wp = build(:work_pattern, flextime: true, core_time_start: "15:00", core_time_end: "10:00")
      expect(wp).not_to be_valid
      expect(wp.errors[:core_time_end]).to be_present
    end

    it "揃っていれば valid。flextime: false の core 残存は許容（無視される値）" do
      expect(build(:work_pattern, flextime: true, core_time_start: "10:00", core_time_end: "15:00")).to be_valid
      expect(build(:work_pattern, flextime: false, core_time_start: "10:00", core_time_end: "15:00")).to be_valid
    end

    it "夜勤フレックスは日跨ぎコアタイム（23:00–03:00）が valid（鏡像 — 無条件逆転拒否への退行検知）" do
      wp = build(:work_pattern, night_shift: true, flextime: true,
                 start_time: "22:00", end_time: "07:00",
                 core_time_start: "23:00", core_time_end: "03:00")
      expect(wp).to be_valid
    end

    it "コアタイム開始=終了（縮退）は夜勤でも invalid" do
      wp = build(:work_pattern, night_shift: true, flextime: true,
                 start_time: "22:00", end_time: "07:00",
                 core_time_start: "23:00", core_time_end: "23:00")
      expect(wp).not_to be_valid
      expect(wp.errors[:core_time_end]).to be_present
    end
  end

  describe "時刻逆転（0b-2 設計 §2 補強 2）" do
    it "night_shift: false で start >= end は invalid" do
      expect(build(:work_pattern, start_time: "22:00", end_time: "07:00")).not_to be_valid
      expect(build(:work_pattern, start_time: "09:00", end_time: "09:00")).not_to be_valid
    end

    it "night_shift: true なら start > end が valid（夜勤の鏡像 — 条件なし逆転拒否の誤実装検知）" do
      expect(build(:work_pattern, night_shift: true, start_time: "22:00", end_time: "07:00")).to be_valid
    end
  end

  describe "#mode_conflict?" do
    it "night_shift × flextime の同時指定で true（保存は許可）" do
      wp = build(:work_pattern, night_shift: true, flextime: true,
                 start_time: "22:00", end_time: "07:00",
                 core_time_start: "23:00", core_time_end: "03:00")
      expect(wp).to be_valid
      expect(wp.mode_conflict?).to be(true)
      expect(build(:work_pattern).mode_conflict?).to be(false)
    end
  end

  describe "無効化ガード（0b-4 設計 §3・User ガード②同型）" do
    let(:pattern) { create(:work_pattern) }
    let(:org) { pattern.organization }

    def assign(user_name, end_date:, active: true)
      employee = create(:user, name: user_name)
      create(:user_work_pattern, user: employee, work_pattern: pattern,
             start_date: Date.new(2026, 1, 1), end_date: end_date, active: active)
    end

    it "今日以降も有効な割当（無期限）があれば無効化拒否" do
      assign("田中太郎", end_date: nil)
      expect(pattern.update(active: false)).to be(false)
      expect(pattern.errors[:base].join).to include("田中太郎").and include("先に割当を付け替えてください")
    end

    it "過去のみの割当なら許可" do
      assign("田中太郎", end_date: org.today - 1)
      expect(pattern.update(active: false)).to be(true)
    end

    it "今日終了の割当があれば無効化拒否（end_date >= today の境界）" do
      assign("田中太郎", end_date: org.today)
      expect(pattern.update(active: false)).to be(false)
    end

    it "割当なしなら許可" do
      expect(pattern.update(active: false)).to be(true)
    end

    it "inactive 割当のみなら許可（誤登録の論理削除は妨げない）" do
      assign("田中太郎", end_date: nil, active: false)
      expect(pattern.update(active: false)).to be(true)
    end

    it "文言は先頭 3 名 + 他 N 名（flash 肥大防止）" do
      %w[田中太郎 佐藤花子 鈴木一郎 高橋次郎 伊藤三郎].each { |n| assign(n, end_date: nil) }
      pattern.update(active: false)
      message = pattern.errors[:base].join
      expect(message).to include("田中太郎、佐藤花子、鈴木一郎 他 2 名")
      expect(message).not_to include("高橋次郎")
    end

    it "without_tenant 文脈でも保護される" do
      assign("田中太郎", end_date: nil)
      ActsAsTenant.without_tenant do
        expect(pattern.update(active: false)).to be(false)
      end
    end

    it "mismatched with_tenant 文脈（誤テナント設定中の console 操作）でも保護される" do
      assign("田中太郎", end_date: nil)
      ActsAsTenant.with_tenant(create(:organization)) do
        expect(pattern.update(active: false)).to be(false)
      end
    end

    it "再有効化（active: true への遷移）はガード対象外" do
      pattern.update!(active: false)
      expect(pattern.update(active: true)).to be(true)
    end
  end
end

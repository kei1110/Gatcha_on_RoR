# 本番実行を拒否 — 既知パスワードの管理者が本番に残る事故の遮断
abort("seeds は development/test 専用です") unless Rails.env.development? || Rails.env.test?

# ENV 提供時は出力しない — CI ログへの平文残留防止
password = ENV.fetch("SEED_PASSWORD") do
  SecureRandom.alphanumeric(20).tap { |pw| puts "==> seed ユーザーの共通パスワード（自動生成）: #{pw}" }
end

[
  { name: "Acme", subdomain: "acme" },
  { name: "Globex", subdomain: "globex" }
].each do |attrs|
  org = Organization.find_or_create_by!(subdomain: attrs[:subdomain]) do |o|
    o.name = attrs[:name]
  end

  # リクエスト文脈を持たない経路ゆえ明示ラップ（SPEC §3.6）
  ActsAsTenant.with_tenant(org) do
    admin = User.find_or_create_by!(email: "admin@#{org.subdomain}.example.com") do |u|
      u.name = "#{org.name} 管理者"
      u.employee_code = "#{org.subdomain.upcase}-001"
      u.role = :hr_admin
      u.password = password
    end

    boss = User.find_or_create_by!(email: "manager@#{org.subdomain}.example.com") do |u|
      u.name = "#{org.name} 上長"
      u.employee_code = "#{org.subdomain.upcase}-002"
      u.role = :manager
      u.password = password
    end

    User.find_or_create_by!(email: "employee@#{org.subdomain}.example.com") do |u|
      u.name = "#{org.name} 社員"
      u.employee_code = "#{org.subdomain.upcase}-003"
      u.role = :employee
      u.manager = boss
      u.password = password
    end

    # 初期マスタ（0b-2）。found 経路はバリデーションを通らないため再実行で落ちない（冪等）
    WorkPattern.find_or_create_by!(name: "日勤") do |wp|
      wp.start_time = "09:00"; wp.end_time = "18:00"
      wp.break_minutes = 60; wp.standard_work_hours = 8
    end
    WorkPattern.find_or_create_by!(name: "夜勤") do |wp|
      wp.start_time = "22:00"; wp.end_time = "07:00"
      wp.break_minutes = 60; wp.standard_work_hours = 8; wp.night_shift = true
    end
    WorkPattern.find_or_create_by!(name: "フレックス") do |wp|
      wp.start_time = "09:00"; wp.end_time = "18:00"
      wp.break_minutes = 60; wp.standard_work_hours = 8
      wp.flextime = true; wp.core_time_start = "10:00"; wp.core_time_end = "15:00"
    end

    LeaveType.find_or_create_by!(name: "有給休暇") do |lt|
      lt.system_type = :annual; lt.paid_leave = true; lt.allow_half_day = true
    end
    LeaveType.find_or_create_by!(name: "慶弔休暇") { |lt| lt.system_type = :other }
    LeaveType.find_or_create_by!(name: "振替休日") { |lt| lt.system_type = :substitute_holiday }
    LeaveType.find_or_create_by!(name: "代休") { |lt| lt.system_type = :compensatory_leave }

    puts "==> #{org.name}: #{User.count} users (admin: #{admin.email})"
  end
end

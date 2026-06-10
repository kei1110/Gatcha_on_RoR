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

    puts "==> #{org.name}: #{User.count} users (admin: #{admin.email})"
  end
end

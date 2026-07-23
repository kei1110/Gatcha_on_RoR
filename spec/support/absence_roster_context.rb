# frozen_string_literal: true

# 欠勤確定/取消の request spec が共有するロスター（hr → manager → sub の階層 + 別部下 stranger）。
# absence_confirmations_spec と absence_cancellations_spec で verbatim 重複していたものを集約し
# drift を防ぐ（/simplify simplification 4）。
RSpec.shared_context "absence roster" do
  let!(:org) { create(:organization, subdomain: "acme", time_zone: "Asia/Tokyo") }
  let!(:hr)       { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin, name: "人事 花子") } }
  let!(:manager)  { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: hr, name: "上長 一郎") } }
  let!(:sub)      { ActsAsTenant.with_tenant(org) { create(:user, manager: manager, name: "部下 太郎") } }
  let!(:stranger) { ActsAsTenant.with_tenant(org) { create(:user, manager: hr, name: "他部 次郎") } }
end

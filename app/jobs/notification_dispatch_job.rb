# frozen_string_literal: true

# 通知配信のディスパッチャ（設計 §4.3 / §4.4 / §9⑪）。current_tenant = nil 前提で
# Organization をスコープ外列挙し、子に org_id だけ渡す（§3.6）。毎時 recurring。
# 正当化: enqueue 取りこぼし回収（Delivery 作成済・enqueue 前クラッシュ）＋
# 4-2/4-3 が踏襲する dispatcher 雛形の規範実装（§9⑪）。
class NotificationDispatchJob < ApplicationJob
  def perform
    Organization.active.find_each do |org|
      NotificationDispatchTenantJob.perform_later(org.id)
    end
  end
end

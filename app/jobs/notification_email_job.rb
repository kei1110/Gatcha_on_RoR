# frozen_string_literal: true

# email 配信ジョブ（設計 §4.3 / §9⑦⑧）。Notifier が set(wait_until:).perform_later で予約、
# ディスパッチャ子ジョブが取りこぼし回収で再 enqueue する。
# 後送ゆえ実行時はテナント文脈が消失 → 冒頭 with_tenant で再確立（§3.6・check-job-tenant-wrap 対象）。
class NotificationEmailJob < ApplicationJob
  # transient な配送失敗は再試行（§9⑧）。executions が ActiveJob 組込で増え、枯渇時に error 確定。
  RETRYABLE = [ Net::OpenTimeout, Net::ReadTimeout, Net::SMTPServerBusy, Errno::ECONNREFUSED ].freeze
  MAX_ATTEMPTS = 4 # 1 初回 + 3 リトライ

  # リトライ枯渇（attempts 到達）で error 確定。block は送信失敗 tx（perform の with_lock）の外で走る。
  # retry_count 列は executions の監査ミラー（§9⑧・SolidQueue と二重管理しない）。
  retry_on(*RETRYABLE, wait: :polynomially_longer, attempts: MAX_ATTEMPTS) do |job, error|
    organization_id, delivery_id = job.arguments.first.values_at(:organization_id, :delivery_id)
    org = Organization.find_by(id: organization_id)
    if org # retry 中に組織が削除され得る → 未処理例外で error 確定を漏らさない
      ActsAsTenant.with_tenant(org) do
        delivery = NotificationDelivery.find_by(id: delivery_id)
        delivery&.with_lock do
          next if delivery.sent? # 競合で送信済みなら error にしない
          delivery.update!(status: :error, retry_count: job.executions - 1)
        end
      end
    end
    Rails.logger.error("[NotificationEmail] ##{delivery_id} error after #{job.executions} executions: #{error.class}")
  end

  def perform(organization_id:, delivery_id:)
    org = Organization.find_by(id: organization_id)
    return if org.nil? # 組織削除済みは無視（block 側の nil 安全と対称）

    ActsAsTenant.with_tenant(org) do # §3.6 必須（リクエスト文脈なし）
      delivery = NotificationDelivery.find_by(id: delivery_id)
      return if delivery.nil? # 削除済みは無視

      # SMTP I/O 間の行ロック保持は意図的（低ボリューム前提・§9⑧）。
      # status 遷移の書き込みはこの with_lock 内に集約（散在状態機械にしない）。
      delivery.with_lock do
        return unless delivery.pending? # 冪等: sent/error は二重送信しない

        NotificationMailer.notify(delivery.notification).deliver_now
        delivery.update!(status: :sent, retry_count: executions - 1)
      end
    end
  end
end

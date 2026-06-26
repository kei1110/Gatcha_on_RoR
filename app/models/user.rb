# frozen_string_literal: true

class User < ApplicationRecord
  acts_as_tenant(:organization)

  # :validatable は載せない — 一意性検証だけの差し替えが不可能なため自前検証（devise#4767）
  # :registerable も載せない — 公開サインアップなし（SPEC §3.2）
  # :rememberable と :timeoutable の併用は Devise 既定（remembered ユーザーは timeout 免除）を容認
  devise :database_authenticatable, :recoverable, :rememberable,
         :lockable, :trackable, :timeoutable

  belongs_to :manager, class_name: "User", optional: true
  has_many :subordinates, class_name: "User",
           foreign_key: :manager_id, inverse_of: :manager, dependent: :nullify
  has_many :user_work_patterns, dependent: :destroy
  has_many :attendance_records, dependent: :restrict_with_error
  has_many :leave_balances, dependent: :destroy
  has_many :leave_requests, foreign_key: :requester_id, inverse_of: :requester, dependent: :destroy
  has_many :holiday_work_requests, foreign_key: :requester_id, inverse_of: :requester, dependent: :destroy
  has_one :notification_preference, class_name: "UserNotificationPreference", dependent: :destroy
  has_many :notifications, foreign_key: :target_user_id, inverse_of: :target_user, dependent: :destroy

  enum :role, { employee: 0, manager: 1, hr_admin: 2 }, validate: true

  normalizes :email, with: ->(email) { email.strip.downcase }
  before_validation :assign_internal_password, on: :create

  # validatable 相当の自前検証
  validates :email, presence: true, format: { with: Devise.email_regexp }
  validates_uniqueness_to_tenant :email
  validates :password, presence: true, confirmation: true,
            length: { within: Devise.password_length }, if: :password_required?
  validates :name, presence: true
  validates :employee_code, presence: true
  validates_uniqueness_to_tenant :employee_code
  validate :manager_must_belong_to_same_organization
  validate :hr_admin_lockout_guard, on: :update
  validate :deactivation_requires_no_active_subordinates, on: :update
  validate :manager_chain_must_not_cycle, if: :manager_id_changed?
  validate :manager_must_be_active, if: -> { manager_id_changed? || (active_changed? && active?) }

  # 承認済 HWR が当日にあるか（ClockIn/ProxyClockIn が打刻 AR の is_holiday_work 初期値に使う・§2.3）。
  # acts_as_tenant default_scope + association 起点ゆえ他人/他テナントの HWR を拾わない。
  def holiday_work_reserved_on?(date) = holiday_work_requests.approved.exists?(work_date: date)

  # 在籍フラグを認証に接続（fail-closed）
  def active_for_authentication?
    super && active?
  end

  # 退職者の存在を応答差で漏らさない（paranoid と整合）
  def inactive_message
    active? ? super : :invalid
  end

  # 招待メール送付（recoverable 転用・0b-1 設計 §2-2）。
  # protected な set_reset_password_token への依存をこの 1 箇所に閉じ込める
  # （recoverable の send_reset_password_instructions の鏡像）。
  # send_devise_notification は deliver_now — リクエスト文脈内で送る（§3.6 ジョブ経路を作らない）
  # 注意: set_reset_password_token は save(validate: false) を伴う — 保存済み・クリーンな
  # レコードに対してのみ呼ぶこと。戻り値の raw token を flash・ログ・レスポンスへ出さない
  def send_invitation_instructions
    raw_token = set_reset_password_token
    send_devise_notification(:invitation_instructions, raw_token, {})
    raw_token
  end

  class << self
    # Devise の session 復元はテナント解決（controller before_action）より先に走り得る
    # （require_no_authentication が prepend のため）。unscoped で引き、テナント突合は
    # warden_tenant_guard（after_set_user・fail-closed）が単一点で担う
    def serialize_from_session(*args)
      ActsAsTenant.without_tenant { super }
    end

    # remember cookie 経由の復元も同型（rememberable の no-input 戦略は require_no_authentication
    # 内の warden.authenticate? で発火し、テナント解決より先に走る）。突合は warden_tenant_guard
    def serialize_from_cookie(*args)
      ActsAsTenant.without_tenant { super }
    end

    # acts_as_tenant の default scope に加えた明示防衛（scope が外れた経路への二重化）
    def find_for_database_authentication(warden_conditions)
      tenant = ActsAsTenant.current_tenant
      return nil unless tenant

      find_by(organization_id: tenant.id,
              email: warden_conditions[:email].to_s.strip.downcase)
    end

    # recoverable / lockable の発行系が通る経路も同様にスコープ
    def find_first_by_auth_conditions(tainted_conditions, opts = {})
      tenant = ActsAsTenant.current_tenant
      return nil unless tenant

      super(tainted_conditions, opts.merge(organization_id: tenant.id))
    end

    # トークン消費の再検証 — トークンが属するテナントが正・URL のサブドメインを信頼しない
    def with_reset_password_token(token)
      super&.tap do |user|
        tenant = ActsAsTenant.current_tenant
        raise ActiveRecord::RecordNotFound if tenant && user.persisted? && user.organization_id != tenant.id
      end
    end

    # unlock トークンも同様に再検証（設計 §4: reset と unlock の両方が対象）。
    # Devise 5 の lockable に with_unlock_token は存在せず、消費経路は unlock_access_by_token。
    # super は返却前に unlock_access! まで実行するため、後置 tap では解錠済みになる —
    # よって super の前にトークン所有者のテナントを突合する
    def unlock_access_by_token(unlock_token)
      tenant = ActsAsTenant.current_tenant
      digest = Devise.token_generator.digest(self, :unlock_token, unlock_token)
      if tenant && digest.present?
        owner = ActsAsTenant.without_tenant { find_by(unlock_token: digest) }
        raise ActiveRecord::RecordNotFound if owner && owner.organization_id != tenant.id
      end
      super
    end
  end

  private

  # 招待作成は不可知ランダムパスワードで password presence を満たす（§2.2-2 の「軽微な値セット」。
  # 誰にも開示せず、本人は招待リンク（reset token）でパスワードを設定する）
  def assign_internal_password
    return if password.present? || encrypted_password.present?

    self.password = SecureRandom.hex(32)
  end

  def password_required?
    !persisted? || password.present? || password_confirmation.present?
  end

  def manager_must_belong_to_same_organization
    return if manager_id.nil?
    # acts_as_tenant のスコープ下では他テナントの manager は解決されず nil になる。
    # nil（=スコープ外）も明示エラーにすることで §3.6(2) のバリデーション層を担う
    return if manager&.organization_id == organization_id

    errors.add(:manager_id, "は同一組織のユーザーである必要があります")
  end

  # ガード①: 最後のアクティブ hr_admin の降格・無効化を拒否（締め出し防止・0b-1 設計 §3）
  def hr_admin_lockout_guard
    was_active_admin = (role_changed? ? role_was == "hr_admin" : hr_admin?) &&
                       (active_changed? ? active_was : active?)
    still_active_admin = hr_admin? && active?
    return unless was_active_admin && !still_active_admin
    return if other_active_hr_admin_exists?

    errors.add(:base, "組織最後の管理者は降格・無効化できません")
  end

  # organization_id を明示 — without_tenant 文脈（console/seed）で全テナント横断 COUNT に
  # なる fail-open を遮断する（0a の「default scope に加えた明示防衛」と同型）
  def other_active_hr_admin_exists?
    self.class.where(organization_id: organization_id, role: :hr_admin, active: true)
        .where.not(id: id).exists?
  end

  # ガード②: アクティブな部下を残したままの無効化を拒否（不在上長の発生防止・0b-1 設計 §3）
  # ②③④の association 経由クエリは organization_id 非明示だが、複合 FK
  # (organization_id, manager_id) がクロステナント参照を DB レベルで排除済み（①は COUNT 系で FK の保護が及ばないため明示）
  def deactivation_requires_no_active_subordinates
    return unless active_changed? && !active

    count = subordinates.where(active: true).count
    return if count.zero?

    errors.add(:base, "アクティブな部下が #{count} 名います。先に上長を付け替えてください")
  end

  # ガード③: visited-set 方式の循環検出（深さ定数を持たない — §2.2-5 の「再帰ガード」型を避ける）。
  # Phase 1 の subordinate_of?（部下可視性）が全段遡上するため、書き込み時に不変条件を守る。
  # 既知の限界: A.manager=B / B.manager=A の並行 save の競合窓は v1 受容（設計 §3）
  def manager_chain_must_not_cycle
    return if manager_id.nil?

    visited = Set[id]
    node = manager
    while node
      if visited.include?(node.id)
        errors.add(:manager_id, "は循環しています")
        return
      end
      visited << node.id
      node = node.manager
    end
  end

  # ガード④: 無効化済みユーザーの上長指定を拒否（②は無効化側・こちらは代入側の対称防御）
  def manager_must_be_active
    return if manager_id.nil? || manager.nil? # nil（スコープ外）は同一組織バリデーションが拾う
    return if manager.active?

    errors.add(:manager_id, "は在籍中（アクティブ）のユーザーである必要があります")
  end
end

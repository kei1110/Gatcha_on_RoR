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

  enum :role, { employee: 0, manager: 1, hr_admin: 2 }

  normalizes :email, with: ->(email) { email.strip.downcase }

  # validatable 相当の自前検証
  validates :email, presence: true, format: { with: Devise.email_regexp }
  validates_uniqueness_to_tenant :email
  validates :password, presence: true, confirmation: true,
            length: { within: Devise.password_length }, if: :password_required?
  validates :name, presence: true
  validates :employee_code, presence: true
  validates_uniqueness_to_tenant :employee_code
  validate :manager_must_belong_to_same_organization

  # 在籍フラグを認証に接続（fail-closed）
  def active_for_authentication?
    super && active?
  end

  # 退職者の存在を応答差で漏らさない（paranoid と整合）
  def inactive_message
    active? ? super : :invalid
  end

  class << self
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
end

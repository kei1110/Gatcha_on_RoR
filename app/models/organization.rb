class Organization < ApplicationRecord
  # テナントルートゆえ acts_as_tenant を付けない（SPEC §3.1）
  has_many :users, dependent: :restrict_with_error

  validates :name, presence: true
  validates :subdomain, presence: true, uniqueness: true,
            format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
                      message: "は小文字英数とハイフンのみ使用できます" }
  validates :time_zone, presence: true
end

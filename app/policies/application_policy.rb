class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  # 既定 deny — 許可は各ポリシーで明示的に開ける
  def index? = false
  def show? = false
  def create? = false
  def new? = create?
  def update? = false
  def edit? = update?
  def destroy? = false

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    # 既定 deny — 一覧も明示的に開けるまで空
    def resolve
      scope.none
    end

    private

    attr_reader :user, :scope
  end
end

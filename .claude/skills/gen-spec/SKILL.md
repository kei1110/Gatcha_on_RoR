---
name: gen-spec
description: 本リポジトリのテナント文脈規約に沿った RSpec（model / policy / request / system / job）の雛形生成と作法の参照に使う。TRIGGER - 新モデル・policy・コントローラ・ジョブの spec を書くとき / ユーザーが「gen-spec」「spec 生成」「テスト雛形」「spec の書き方」に言及 / Claude 自身が spec を新規作成する直前。DO NOT TRIGGER - 既存 spec の軽微修正（1 example 程度）/ spec 以外のテストインフラ（rails_helper・support）自体の変更。
---

# gen-spec — テナント文脈に安全な RSpec 雛形

`require_tenant = true` の本リポジトリでは、テナント文脈を誤った spec は `ActsAsTenant::Errors::NoTenantSet` で落ちるか、より悪い場合**偽の green**（全テナント横断で通ってしまう）になる。本 skill は spec 種別ごとの正しい文脈と、必須コンベンションを規定する。

## 前提 — このリポジトリのテスト基盤（spec/support/）

| 仕組み | 内容 |
|---|---|
| `tenant.rb` | **model / policy 等の spec には `ActsAsTenant.test_tenant` を自動設定**（organization が勝手に立つ）。**request / system には意図的に設定しない** — テナント解決フィルタ自体を検証するため（偽テスト防止）。spec 内で test_tenant を立て直さないこと |
| `tenant_request_helpers.rb` | `tenant_host(org)` → `"#{org.subdomain}.example.com"`。request / system に include 済み。Devise の `sign_in` も request で利用可 |
| factory（users.rb） | `organization { ActsAsTenant.current_tenant \|\| ActsAsTenant.test_tenant \|\| association(:organization) }` のフォールバック。**新 factory のテナント帰属カラムは必ずこの行を踏襲**する |

## 必須コンベンション（新モデルの spec に漏れなく入れる 3 点セット）

§3.6（テナント分離）を spec レベルで担保する。`spec/models/user_spec.rb` が見本:

1. **テナント内 unique**: `create(:x, key: v)` → `build(:x, key: v)` が invalid
2. **鏡像テスト（クロステナント許可）**: `ActsAsTenant.with_tenant(create(:organization)) { build(:x, key: v) が valid }`
3. **DB 最終防衛**: `save!(validate: false)` で `ActiveRecord::RecordNotUnique` が上がる（複合 unique index の実在確認）

ユーザー参照（自己参照 FK 含む）を持つモデルは追加で:
4. **他テナント id の代入拒否**: 他 org の `User.id` を代入 → invalid（§3.6-(2) のバリデーション確認）

## 種別ごとの雛形

### model spec — 文脈は自動。何も立てない

```ruby
require "rails_helper"

RSpec.describe Foo, type: :model do
  # test_tenant が自動設定済み。create(:foo) はそのテナントに属する
  describe "code" do
    it "is unique within tenant" do
      create(:foo, code: "A")
      expect(build(:foo, code: "A")).not_to be_valid
    end

    it "allows same code in another tenant (鏡像)" do
      create(:foo, code: "A")
      ActsAsTenant.with_tenant(create(:organization)) do
        expect(build(:foo, code: "A")).to be_valid
      end
    end

    it "is enforced by composite unique index at DB level" do
      foo = create(:foo, code: "A")
      dup = build(:foo, code: "A", organization: foo.organization)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
```

### policy spec — pundit-matchers

```ruby
require "rails_helper"

RSpec.describe FooPolicy, type: :policy do
  subject { described_class.new(user, foo) }

  let(:foo) { create(:foo) }

  context "employee（本人）" do
    let(:user) { foo.user }
    it { is_expected.to permit_actions(%i[show]) }
    it { is_expected.to forbid_actions(%i[update destroy]) }
  end

  context "manager（部下のレコード）" do
    let(:user) { create(:user, :manager_role) }
    # 上長階層の設定をここで
  end

  describe "Scope" do
    it "returns own + subordinates' records only" do
      # resolve の件数・内訳を検証。「自分 + 部下」（§3.4）
    end
  end
end
```

### request spec — test_tenant は無い。host でテナントを名乗る

```ruby
require "rails_helper"

RSpec.describe "Foos", type: :request do
  let(:org)  { create(:organization) }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  before { sign_in user }

  it "lists foos" do
    get foos_path, headers: { "HOST" => tenant_host(org) }
    expect(response).to have_http_status(:ok)
  end

  it "does not leak another tenant's records" do
    other = create(:organization)
    ActsAsTenant.with_tenant(other) { create(:foo) }
    get foos_path, headers: { "HOST" => tenant_host(org) }
    # 他テナントのレコードが応答に含まれないこと
  end
end
```

注意: factory 呼び出しは `with_tenant` で**明示的に**包む（自動文脈が無いため。包み忘れは `NoTenantSet` で即落ちる — それが正しい挙動）。

### system spec — capybara_tenant.rb 参照。subdomain 付き URL で訪問

`spec/system/tenant_isolation_spec.rb` を見本に。`tenant_host(org)` でホストを切り替え、ログイン〜画面遷移を検証する。

### job spec — ディスパッチャ／子ジョブの 2 層を別々に検証（§3.6-(1)）

```ruby
require "rails_helper"

RSpec.describe FooDispatchJob, type: :job do
  it "enqueues one child job per active organization" do
    orgs = create_list(:organization, 2)
    expect { described_class.perform_now }
      .to have_enqueued_job(FooTenantJob).exactly(orgs.count).times
  end
end

RSpec.describe FooTenantJob, type: :job do
  let(:org) { create(:organization) }

  it "processes only the given tenant's records" do
    target = ActsAsTenant.with_tenant(org) { create(:foo) }
    other  = ActsAsTenant.with_tenant(create(:organization)) { create(:foo) }
    described_class.perform_now(org.id)
    # target のみ処理され other が無傷であることを検証（クロステナント漏洩の negative test）
  end
end
```

## 手順

1. 対象（モデル / policy / コントローラ / ジョブ）と種別を確定する
2. 上記雛形を適用し、ドメイン固有の example を肉付けする。**3 点セット（+ユーザー参照なら 4）を省略しない**
3. 新 factory が要るなら organization フォールバック行を踏襲して `spec/factories/` に追加
4. `bundle exec rspec <生成した spec ファイル>` を実行し、green を確認してから報告する

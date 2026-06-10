require "rails_helper"

RSpec.describe Organization, type: :model do
  it "is valid with name and subdomain" do
    expect(build(:organization)).to be_valid
  end

  it "requires globally unique subdomain" do
    create(:organization, subdomain: "acme")
    expect(build(:organization, subdomain: "acme")).not_to be_valid
  end

  it "rejects invalid subdomain format" do
    expect(build(:organization, subdomain: "Bad_Sub!")).not_to be_valid
  end

  it "enforces subdomain uniqueness at DB level" do
    create(:organization, subdomain: "acme")
    dup = build(:organization, subdomain: "acme")
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end

FactoryBot.define do
  factory :custom_field_enumeration do
    sequence(:name) { |n| "name#{n}" }
    active { true }
    sequence(:position)
  end
end

FactoryBot.define do
  factory :issue_priority do
    sequence(:name) { |n| "IssuePriority_#{n}" }
  end
end

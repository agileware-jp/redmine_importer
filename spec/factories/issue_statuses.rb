FactoryBot.define do
  factory :issue_status do
    sequence(:name) { |n| "IssueStatus_#{n}" }
  end
end

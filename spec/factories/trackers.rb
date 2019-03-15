FactoryBot.define do
  factory :tracker do
    sequence(:name) { |n| "Tracker_#{n}" }
    default_status { IssueStatus.first || FactoryBot.create(:issue_status) }
  end
end

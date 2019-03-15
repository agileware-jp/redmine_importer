FactoryBot.define do
  factory :issue do
    project
    tracker { project.trackers.first }
    sequence(:subject) { |n| "Issue_#{n}" }
    status { IssueStatus.first || FactoryBot.create(:issue_status) }
    priority { IssuePriority.first || FactoryBot.create(:issue_priority) }
    author { User.logged.first || FactoryBot.create(:user) }
  end
end

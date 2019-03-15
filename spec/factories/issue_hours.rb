FactoryBot.define do
  factory :issue_hour, class: LycheeIssueDatetime::IssueHour do
    issue
    start_date_hour { 0 }
    due_date_hour { 0 }
  end
end

FactoryBot.define do
  factory :issue_custom_field do
    sequence(:name) { |i| "issue_custom_field_#{i}" }
    projects  { [] }
    trackers  { [Tracker.first || FactoryBot.create(:tracker)] }
    field_format { :string }
    visible { true }
    editable { true }

    trait :enumeration do
      field_format { :enumeration }

      after(:create) do |issue_custom_field|
        3.times do
          issue_custom_field.enumerations << create(:custom_field_enumeration, custom_field: issue_custom_field)
        end
      end
    end
  end
end

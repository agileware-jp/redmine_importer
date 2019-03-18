FactoryBot.define do
  factory :project do
    sequence(:name) { |n| "Project_#{n}" }
    identifier { Project.next_identifier || 'project_1' }
    trackers { [FactoryBot.create(:tracker)] }

    after(:create) do |project|
      if Tracker.count.zero?
        project.trackers << FactoryBot.create_list(:tracker, 3)
      end
    end
  end
end

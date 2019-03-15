FactoryBot.define do
  factory :user do
    sequence(:login) { |n| "Login_#{n}" }
    sequence(:mail) { |n| "mail_#{n}@example.com" }
    sequence(:firstname) { |n| "Firstname_#{n}" }
    sequence(:lastname) { |n| "Lastname_#{n}" }
    password { 'password' }
  end
end

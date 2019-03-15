module LTMHelpers
  def add_permission(user:, project:, permission:)
    add_permissions(user: user, project: project, permissions: Array.wrap(permission))
  end

  def add_permissions(user:, project:, permissions:)
    membership = user.membership(project)
    roles = membership.roles.to_a

    role_with_permission = roles.pop.dup
    role_with_permission.name += ' with permission'
    role_with_permission.permissions += permissions
    role_with_permission.save
    roles.push(role_with_permission)

    membership.update(roles: roles)
  end
end

RSpec::Matchers.alias_matcher :an_array_matching, :match_array

RSpec.configure do |config|
  config.include LTMHelpers
end

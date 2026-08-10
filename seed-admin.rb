# Seed (or re-seed) the first administrator and mark the system as set up.
#
# Run by railway-entrypoint.sh during init, before any process binds a port.
#
# Why this exists: on a stock instance `POST /api/v1/users` with no session is
# routed to UsersController#create_admin, which calls
# Service::User::AddFirstAdmin. That service only refuses once
# Service::System::CheckSetup.done? is true, and CheckSetup is true only once an
# admin user exists (id 1 excluded). Until then, anybody who reaches the public
# URL can create themselves an Admin+Agent account on the deployer's help desk.
#
# Re-seeding on every boot is deliberate: it makes the password in the Railway
# variables panel the password that works, so it can be rotated by redeploying.
# Zammad's own `createsuperuser`-equivalent has no such path.

email     = ENV.fetch('ZAMMAD_ADMIN_EMAIL')
password  = ENV.fetch('ZAMMAD_ADMIN_PASSWORD')
firstname = ENV.fetch('ZAMMAD_ADMIN_FIRSTNAME', 'Admin')
lastname  = ENV.fetch('ZAMMAD_ADMIN_LASTNAME', 'User')

abort('[railway] ZAMMAD_ADMIN_PASSWORD is empty') if password.to_s.strip.empty?

UserInfo.current_user_id = 1

user = User.find_by(email: email.downcase)

if user
  user.password = password
  user.active   = true
  user.save!
  puts "[railway] admin #{email} password re-seeded"
else
  user = User.new(
    firstname: firstname,
    lastname:  lastname,
    email:     email,
    password:  password,
    active:    true,
  )
  user.role_ids  = Role.where(name: %w[Admin Agent]).pluck(:id)
  user.group_ids = Group.pluck(:id)
  user.save!
  puts "[railway] admin #{email} created with roles Admin,Agent"
end

# Close the setup wizard. With this true and an admin present,
# Service::User::AddFirstAdmin raises SystemSetupError, so POST /api/v1/users
# from a stranger is 422 instead of 201.
Setting.set('system_init_done', true)

# Stock deploys leave this at 'zammad.example.com', which is what every
# notification mail, password-reset link and OAuth callback is built from. The
# marketplace listings make setting it a manual post-deploy step in the admin
# UI; Railway already knows the domain, so set it here.
fqdn = ENV['ZAMMAD_FQDN'].to_s.strip
if !fqdn.empty?
  Setting.set('fqdn', fqdn)
  Setting.set('http_type', ENV.fetch('ZAMMAD_HTTP_TYPE', 'https'))
  puts "[railway] fqdn set to #{fqdn}"
end

organization = ENV['ZAMMAD_ORGANIZATION'].to_s.strip
Setting.set('organization', organization) if !organization.empty?

# Never let the instance hand out accounts to the internet by default: Zammad
# ships user_create_account (public signup) enabled.
Setting.set('user_create_account', ENV.fetch('ZAMMAD_ALLOW_SIGNUP', 'false') == 'true')

puts '[railway] setup complete, system_init_done=true'

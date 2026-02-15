Given("I am signed in") do
  @current_user = create_and_sign_in_user
end

Given("I am signed in as an admin") do
  @current_user = create_and_sign_in_admin
end

Given("I am signed in as a regular user") do
  @current_user = create_and_sign_in_user
end

Given("I am signed in as a server owner") do
  @current_user = create_and_sign_in_user
  @server = FactoryBot.create(:server, owner: @current_user)
end

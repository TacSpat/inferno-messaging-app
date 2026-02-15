module AuthenticationHelpers
  def sign_in_user(user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Log In"
  end

  def create_and_sign_in_user(traits: [:confirmed])
    user = FactoryBot.create(:user, *traits, password: "password123")
    sign_in_user(user)
    user
  end

  def create_and_sign_in_admin
    create_and_sign_in_user(traits: [:confirmed, :admin])
  end
end

World(AuthenticationHelpers)

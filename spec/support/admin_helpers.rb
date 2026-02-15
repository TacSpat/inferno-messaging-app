module AdminHelpers
  def sign_in_as_admin
    admin = create(:user, :confirmed, :admin)
    sign_in admin
    admin
  end

  def sign_in_as_user
    user = create(:user, :confirmed)
    sign_in user
    user
  end
end

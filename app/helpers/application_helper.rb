module ApplicationHelper
  def profile_gradient_style(user, direction: "to bottom")
    c1 = user.profile_color.presence || "#2b2d31"
    c2 = user.profile_color_2.presence || c1
    if c1 == c2
      "background-color: #{c1};"
    else
      "background: linear-gradient(#{direction}, #{c1}, #{c2});"
    end
  end

  def profile_card_bg_style(user)
    profile_gradient_style(user, direction: "135deg")
  end
end

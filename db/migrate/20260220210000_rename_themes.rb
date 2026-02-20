class RenameThemes < ActiveRecord::Migration[7.1]
  def up
    execute "UPDATE users SET theme = 'frostfire' WHERE theme = 'midnight'"
    execute "UPDATE users SET theme = 'boron' WHERE theme = 'forest'"
    execute "UPDATE users SET theme = 'brimstone' WHERE theme = 'twilight'"
  end

  def down
    execute "UPDATE users SET theme = 'midnight' WHERE theme = 'frostfire'"
    execute "UPDATE users SET theme = 'forest' WHERE theme = 'boron'"
    execute "UPDATE users SET theme = 'twilight' WHERE theme = 'brimstone'"
  end
end

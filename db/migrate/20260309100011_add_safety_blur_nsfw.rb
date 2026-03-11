class AddSafetyBlurNsfw < ActiveRecord::Migration[8.1]
  def change
    add_column :instance_configs, :safety_blur_nsfw, :boolean, default: true
  end
end

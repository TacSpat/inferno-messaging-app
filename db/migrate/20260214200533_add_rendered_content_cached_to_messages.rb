class AddRenderedContentCachedToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :rendered_content_cached, :text
  end
end

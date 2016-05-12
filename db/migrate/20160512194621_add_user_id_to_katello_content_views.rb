class AddUserIdToKatelloContentViews < ActiveRecord::Migration
  def change
    add_column :katello_content_views, :user_id, :integer
  end
end

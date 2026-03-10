class HiddenAttachmentRecord < ApplicationRecord
  belongs_to :message
  belongs_to :purged_by, class_name: "User"
end

class CallParticipant < ApplicationRecord
  belongs_to :call
  belongs_to :user
end

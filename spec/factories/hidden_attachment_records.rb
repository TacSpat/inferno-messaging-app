FactoryBot.define do
  factory :hidden_attachment_record do
    association :message
    association :purged_by, factory: [ :user, :confirmed ]
    original_filename { "image.png" }
    content_type { "image/png" }
    byte_size { 1024 }
    purged_at { Time.current }
  end
end

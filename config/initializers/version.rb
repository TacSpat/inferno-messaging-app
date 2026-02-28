# frozen_string_literal: true

module Inferno
  VERSION = File.read(Rails.root.join("VERSION")).strip rescue "dev"
end

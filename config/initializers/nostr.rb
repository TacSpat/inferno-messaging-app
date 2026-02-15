# nostr_ruby's lib/bech32.rb shadows the bech32 gem's lib/bech32.rb on $LOAD_PATH.
# This means `require 'bech32'` loads nostr_ruby's wrapper (which opens module Bech32
# with only the Nostr submodule) instead of the base gem that defines encode/decode/convert_bits.
# Force-load the base gem first by its absolute path via Gem.
bech32_spec = Gem.loaded_specs["bech32"]
require "#{bech32_spec.gem_dir}/lib/bech32"

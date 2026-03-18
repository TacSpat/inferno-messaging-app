Feature: Cross-Instance Server Sync
  As a remote instance
  I want to receive full server structure from the authority
  So my local copy matches the original (channels, hierarchy, voice settings, metadata)

  Background:
    Given a server owner exists with a server
    And my server has a nostr group ID

  Scenario: Structure event includes voice channel settings
    Given my server has a voice channel "gaming-voice" with bitrate 128000 and user limit 25
    When the structure is published to relays
    Then the published event should include voice_bitrate "128000"
    And the published event should include voice_user_limit "25"

  Scenario: Structure event includes channel nesting hierarchy
    Given my server has a voice channel "main-voice"
    And my server has a voice channel "sub-voice" nested under "main-voice"
    When the structure is published to relays
    Then the published event should reference "main-voice" as parent of "sub-voice"

  Scenario: Structure event includes sidechat links
    Given my server has a voice channel "voice-room"
    And my server has a text channel "voice-text"
    And "voice-room" is linked to sidechat "voice-text"
    When the structure is published to relays
    Then the published event should reference "voice-text" as sidechat of "voice-room"

  Scenario: Structure event includes post-only flag
    Given my server has a post-only channel "announcements"
    When the structure is published to relays
    Then the published event should include post_only "true" for "announcements"

  Scenario: Metadata event includes AFK channel settings
    Given my server has a voice channel "afk-room"
    And the server AFK channel is "afk-room" with timeout 15 and action "disconnect"
    When the metadata is published to relays
    Then the published metadata should include afk_channel "afk-room"
    And the published metadata should include afk_timeout "15"
    And the published metadata should include afk_action "disconnect"

  Scenario: Metadata event includes server type and age restriction
    Given the server type is "gaming" and age restricted
    When the metadata is published to relays
    Then the published metadata should include server_type "gaming"
    And the published metadata should include age_restricted "true"

  Scenario: Receiving structure event creates channel hierarchy
    When a remote structure event is received with nested channels
    Then the local channels should have correct parent references
    And the local channels should have correct sidechat links

  Scenario: Deleting parent channel nullifies children
    Given my server has a voice channel "parent-vc"
    And my server has a voice channel "child-vc" nested under "parent-vc"
    When I delete the channel "parent-vc"
    Then "child-vc" should still exist
    And "child-vc" should have no parent channel

  Scenario: Per-server sync skips recently synced servers
    Given the server was last synced 30 minutes ago
    When periodic sync runs
    Then the server should not be re-synced
    And the last_synced_at should be unchanged

  Scenario: Per-server sync runs for stale servers
    Given the server was last synced 2 hours ago
    When periodic sync runs
    Then the server should be synced
    And the last_synced_at should be updated

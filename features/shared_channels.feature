Feature: Shared Channel Management
  As a server owner
  I want to bridge channels to NIP-29 groups
  So I can federate conversations with other instances

  Scenario: Owner bridges a channel
    Given I am signed in as a server owner
    And my server has a channel named "general"
    When I bridge the channel to relay "wss://relay.example.com"
    Then the channel should be shared
    And the channel should have a nostr group ID

  Scenario: Owner unbridges a channel
    Given I am signed in as a server owner
    And my server has a shared channel named "general"
    When I unbridge the channel
    Then the channel should not be shared

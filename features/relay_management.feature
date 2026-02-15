Feature: Relay Connection Management
  As an instance administrator
  I want to manage relay connections
  So I can control which Nostr relays my instance communicates with

  Scenario: Admin adds a relay
    Given I am signed in as an admin
    When I add a relay with URL "wss://relay.example.com"
    Then a relay connection should exist with URL "wss://relay.example.com"
    And I should see "added"

  Scenario: Admin tries to add invalid relay URL
    Given I am signed in as an admin
    When I add a relay with URL "https://not-a-websocket.com"
    Then I should see an error about the URL format

  Scenario: Admin disables a relay
    Given I am signed in as an admin
    And a relay "wss://relay.example.com" exists
    When I toggle the relay "wss://relay.example.com"
    Then the relay "wss://relay.example.com" should be disabled

  Scenario: Admin enables a disabled relay
    Given I am signed in as an admin
    And a disabled relay "wss://relay2.example.com" exists
    When I toggle the relay "wss://relay2.example.com"
    Then the relay "wss://relay2.example.com" should be active

  Scenario: Admin removes a relay
    Given I am signed in as an admin
    And a relay "wss://relay.example.com" exists
    When I remove the relay "wss://relay.example.com"
    Then no relay connection should exist with URL "wss://relay.example.com"

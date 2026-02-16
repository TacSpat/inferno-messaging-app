Feature: Cross-instance server creation
  As a signed-in user with a Nostr identity
  I want to create servers on remote instances
  So that I can participate in communities across the federation

  Scenario: Create a server on the local instance (default)
    Given I am signed in
    When I visit the new server page
    And I fill in "Server Name" with "Local Server"
    And I click "Create Server"
    Then I should be on the general channel of "Local Server"
    And the server "Local Server" should have a general channel

  Scenario: Instance picker is visible for users with Nostr keys
    Given I am signed in as a user with Nostr keys
    And there is an active relay connection to "wss://remote.chat"
    When I visit the new server page
    Then I should see "Instance"
    And I should see "remote.chat"

  Scenario: Instance picker is hidden for users without Nostr keys
    Given I am signed in as a user without Nostr keys
    When I visit the new server page
    Then I should not see "Instance"

  Scenario: Federation API accepts valid server creation request
    Given federation is open
    When a remote user sends a valid server creation event for "Federated Server"
    Then the server "Federated Server" should exist
    And the server "Federated Server" should have an invite code
    And the server owner should be a remote user

  Scenario: Federation API rejects when federation is closed
    Given federation is closed
    When a remote user sends a valid server creation event for "Blocked Server"
    Then the federation request should be rejected with "Federation is closed"

  Scenario: Federation API rejects blocklisted instances
    Given federation is open
    And the instance "evil.chat" is blocklisted
    When a remote user from "evil.chat" sends a server creation event for "Evil Server"
    Then the federation request should be rejected with "blocked"

  Scenario: Remote server appears in the server rail
    Given I am signed in
    And I have a remote server reference for "Remote Hangout" on "other.chat"
    When I visit the home page
    Then I should see "Remote Hangout" in the server rail

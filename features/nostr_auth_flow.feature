Feature: Nostr Cross-Instance Authentication
  As a user from a remote instance
  I want to authenticate with my home instance's Nostr identity
  So I can participate in channels on other instances

  Scenario: Initiate authentication redirects to home instance
    When I initiate Nostr auth with home instance "home.chat"
    Then I should be redirected to "home.chat"
    And a Nostr auth challenge should be created

  Scenario: Lockdown blocks remote authentication
    Given the instance has emergency lockdown enabled
    When I initiate Nostr auth with home instance "home.chat"
    Then I should see "currently disabled"
    And no Nostr auth challenge should be created

  Scenario: Blocklist blocks authentication from blocked domain
    Given the domain "evil.chat" is blocklisted
    When I initiate Nostr auth with home instance "evil.chat"
    Then I should see "not allowed"

  Scenario: Closed federation blocks remote authentication
    Given federation mode is "closed"
    When I initiate Nostr auth with home instance "home.chat"
    Then I should see "does not accept remote authentication"

  Scenario: Signing page shows confirmation for logged-in user
    Given I am signed in
    When I visit the signing page with valid params
    Then I should see "wants to verify your identity"

  Scenario: Approving signing redirects to callback
    Given I am signed in
    When I approve the signing request
    Then I should be redirected to the callback URL with a signed event

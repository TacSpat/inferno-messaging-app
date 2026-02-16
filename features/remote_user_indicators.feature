Feature: Remote user visual indicators
  As a server member
  I want to see which users are from remote instances
  So that I understand the federated nature of the community

  Scenario: Remote user shows instance domain in member sidebar
    Given I am signed in as a server owner
    And a remote user "alice" from "other.chat" is a member of my server
    When I visit the general channel of my server
    Then I should see "other.chat" in the member sidebar

  Scenario: Remote user shows instance pill in messages
    Given I am signed in as a server owner
    And a remote user "bob" from "far.away" is a member of my server
    And "bob" has posted a message "Hello from far away!" in my server
    When I visit the general channel of my server
    Then I should see "far.away"
    And I should see "Hello from far away!"

  Scenario: Local user does not show instance indicator
    Given I am signed in as a server owner
    When I visit the general channel of my server
    Then I should not see any remote instance indicators

  Scenario: Server settings shows hosted instance
    Given I am signed in as a server owner
    When I visit my server settings
    Then I should see "Hosted on"

  Scenario: User with remote server sees connected instance in settings
    Given I am signed in as a server owner
    And I have a remote server "Cool Server" on "https://cool.chat"
    When I visit my account settings
    Then I should see "Connected Instances"
    And I should see "cool.chat"
    And I should see "Cool Server"

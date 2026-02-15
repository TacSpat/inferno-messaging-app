Feature: Server and channel management
  As a signed-in user
  I want to create and manage servers and channels
  So that I can organize my communities

  Scenario: Create a server
    Given I am signed in
    When I visit the new server page
    And I fill in "Server Name" with "Cool Server"
    And I click "Create Server"
    Then I should be on the general channel of "Cool Server"
    And the server "Cool Server" should have a general channel
    And the server "Cool Server" should have default roles

  Scenario: Visit a channel
    Given I am signed in as a server owner
    When I visit the general channel of my server
    Then I should see the channel name
    And I should see the message input area

  Scenario: Create a channel in a server
    Given I am signed in as a server owner
    When I create a channel named "announcements" in my server
    Then I should be on the "announcements" channel page

  Scenario: Non-member cannot visit a channel
    Given I am signed in
    And a server "Private Club" exists
    When I try to visit the general channel of "Private Club"
    Then I should be redirected away

  Scenario: Server name validation
    Given I am signed in
    When I visit the new server page
    And I submit the server form with a blank name
    Then I should see a server name error

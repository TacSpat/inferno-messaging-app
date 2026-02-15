Feature: Messaging
  As a signed-in user
  I want to send messages and react to them
  So that I can communicate with other users

  Scenario: Send a text message
    Given I am signed in as a server owner
    And I am in the general channel of my server
    When I send a message with content "Hello everyone!"
    Then a message "Hello everyone!" should exist in the channel

  Scenario: Send a message with an image attachment
    Given I am signed in as a server owner
    And I am in the general channel of my server
    When I send a message with an image attachment
    Then the latest message should have a file attached

  Scenario: Send a message with a video attachment
    Given I am signed in as a server owner
    And I am in the general channel of my server
    When I send a message with a video attachment
    Then the latest message should have a file attached

  Scenario: Send a message with a gif attachment
    Given I am signed in as a server owner
    And I am in the general channel of my server
    When I send a message with a gif attachment
    Then the latest message should have a file attached

  Scenario: React to a message
    Given I am signed in as a server owner
    And I am in the general channel of my server
    And a message "React to this!" exists in the channel
    When I react to the message with "👍"
    Then the message should have a "👍" reaction from me

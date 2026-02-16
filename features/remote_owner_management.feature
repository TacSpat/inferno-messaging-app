Feature: Remote user server ownership and management
  As a remote user who owns a server on another instance
  I want to manage my server fully
  So that I have the same capabilities as a local owner

  Background:
    Given I am signed in as a remote server owner from "home.chat"

  Scenario: Remote owner can view server settings
    When I visit my server settings
    Then I should see my server name

  Scenario: Remote owner can rename the server
    When I update my server name to "Renamed by Remote"
    Then the server should be named "Renamed by Remote"

  Scenario: Remote owner can create a channel
    When I create a channel named "remote-channel" in my server
    Then the server should have a channel named "remote-channel"

  Scenario: Remote owner can kick a member
    Given a local user "troublemaker" is a member of my server
    When I kick "troublemaker" from my server
    Then "troublemaker" should no longer be a member

  Scenario: Remote owner can create an invite
    When I create an invite for my server
    Then my server should have a new invite

  Scenario: Remote owner can view members list
    Given a local user "friend" is a member of my server
    When I visit my server members settings
    Then I should see my server name

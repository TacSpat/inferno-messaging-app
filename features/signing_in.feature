Feature: Signing in
  As a user
  I want to sign in to Inferno Chat
  So that I can access my servers and messages

  Scenario: Successful sign in
    Given a confirmed user exists with email "alice@example.com"
    When I visit the login page
    And I fill in my credentials with email "alice@example.com" and password "password123"
    And I click "Log In"
    Then I should be on the authenticated root page

  Scenario: Invalid credentials
    Given a confirmed user exists with email "alice@example.com"
    When I visit the login page
    And I fill in my credentials with email "alice@example.com" and password "wrongpassword"
    And I click "Log In"
    Then I should see "Invalid email or password"
    And I should be on the login page

  Scenario: Unconfirmed user
    Given an unconfirmed user exists with email "bob@example.com"
    When I visit the login page
    And I fill in my credentials with email "bob@example.com" and password "password123"
    And I click "Log In"
    Then I should see a confirmation error
    And I should be on the login page

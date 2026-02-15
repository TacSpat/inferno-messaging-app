Feature: Registration During Lockdown
  As an instance administrator
  I want to control registrations during lockdown
  So I can prevent new signups when needed

  Scenario: Signup is blocked during lockdown
    Given the instance has local signups blocked
    When I try to sign up
    Then I should be redirected to the login page
    And I should see "currently disabled"

  Scenario: Signup works normally without lockdown
    When I try to sign up
    Then I should see the registration form

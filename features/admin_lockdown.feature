Feature: Instance Lockdown Management
  As an instance administrator
  I want to control lockdown settings
  So I can protect the instance during emergencies

  Scenario: Admin activates emergency lockdown
    Given I am signed in as an admin
    When I activate emergency lockdown
    Then all lockdown flags should be enabled
    And I should see "Emergency lockdown activated"

  Scenario: Admin lifts lockdown
    Given I am signed in as an admin
    And the instance has emergency lockdown enabled
    When I lift the lockdown
    Then all lockdown flags should be disabled
    And I should see "All lockdowns lifted"

  Scenario: Admin toggles granular lockdowns
    Given I am signed in as an admin
    When I update instance settings with "lockdown_remote_auth" enabled
    Then remote auth should be blocked

  Scenario: Non-admin is blocked from admin area
    Given I am signed in as a regular user
    When I try to access the admin instance config
    Then I should be redirected away
    And I should see "don't have access"

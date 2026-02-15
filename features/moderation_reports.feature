Feature: Moderation Reports
  As an instance admin and user
  I want to submit and manage moderation reports
  So I can keep the instance safe

  Scenario: User submits a moderation report
    Given I am signed in as a regular user
    When I submit a moderation report for pubkey "abc123" with type "spam"
    Then a moderation report should exist with status "open"

  Scenario: Admin views open reports
    Given I am signed in as an admin
    And there are open moderation reports
    When I visit the moderation reports page
    Then I should see the reports listed

  Scenario: Admin marks report as reviewed
    Given I am signed in as an admin
    And there is an open moderation report
    When I mark the report as "reviewed"
    Then the report status should be "reviewed"

  Scenario: Admin actions report with NIP-56 publish
    Given I am signed in as an admin
    And there is an open moderation report
    When I action the report with NIP-56 publishing
    Then the report status should be "actioned"
    And a NIP-56 report should be queued for publishing

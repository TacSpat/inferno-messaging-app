Feature: NIP-49 Encrypted Key Export
  As a user
  I want to export my Nostr private key encrypted
  So I can safely back it up

  Scenario: Export encrypted key with valid password
    Given I am signed in as a regular user
    When I export my encrypted key with password "password123" and backup password "backuppass123"
    Then I should receive an ncryptsec string

  Scenario: Export fails with wrong account password
    Given I am signed in as a regular user
    When I export my encrypted key with password "wrong_password" and backup password "backuppass123"
    Then I should see an error about incorrect password

  Scenario: Export fails with short backup password
    Given I am signed in as a regular user
    When I export my encrypted key with password "password123" and backup password "short"
    Then I should see an error about backup password length

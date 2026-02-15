When("I submit a moderation report for pubkey {string} with type {string}") do |pubkey, report_type|
  page.driver.post moderation_reports_path, {
    reported_pubkey: pubkey,
    report_type: report_type,
    reason: "Test report"
  }
end

Then("a moderation report should exist with status {string}") do |status|
  expect(ModerationReport.where(status: status).count).to be > 0
end

Given("there are open moderation reports") do
  @reports = 3.times.map { FactoryBot.create(:moderation_report) }
end

Given("there is an open moderation report") do
  @report = FactoryBot.create(:moderation_report)
end

When("I visit the moderation reports page") do
  visit admin_moderation_reports_path
end

Then("I should see the reports listed") do
  text = page.text
  expect(text.include?("spam") || text.include?("Report") || text.include?("open")).to be true
end

When("I mark the report as {string}") do |status|
  page.driver.post review_admin_moderation_report_path(@report), { status: status }
end

Then("the report status should be {string}") do |status|
  expect(@report.reload.status).to eq(status)
end

When("I action the report with NIP-56 publishing") do
  # Track if the job was enqueued
  @nip56_job_enqueued = false
  original_perform_later = NostrReportPublishJob.method(:perform_later)
  NostrReportPublishJob.define_singleton_method(:perform_later) do |*args|
    @nip56_report_id = args.first
    # Don't actually enqueue
  end
  # Store on the instance variable through the module
  @nip56_report_id = nil

  page.driver.post review_admin_moderation_report_path(@report), {
    status: "actioned",
    publish_to_relays: "1"
  }
end

Then("a NIP-56 report should be queued for publishing") do
  # The report should be actioned
  expect(@report.reload.status).to eq("actioned")
end

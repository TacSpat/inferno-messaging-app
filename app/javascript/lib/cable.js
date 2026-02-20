import { createConsumer } from "@rails/actioncable"

// Single shared ActionCable consumer for the entire app.
// All controllers should import this instead of calling createConsumer() directly.
export default createConsumer()

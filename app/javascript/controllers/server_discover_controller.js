import { Controller } from "@hotwired/stimulus"
import { fetchDiscoverServers } from "../lib/server_discover"

// Used on servers/new.html.erb (no teleportation, Stimulus works normally)
export default class extends Controller {
  static targets = ["list"]

  connect() {
    fetchDiscoverServers(this.listTarget)
  }
}

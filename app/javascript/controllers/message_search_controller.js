import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["searchWrap", "searchBar", "query", "chipsArea", "suggestions",
                     "autocomplete", "autocompleteHeader", "autocompleteList",
                     "datePicker", "datePickerLabel", "datePickerInput",
                     "sidebar", "sidebarResults", "sidebarLoading", "resultCount",
                     // Mobile targets
                     "mobileOverlay", "mobileQuery", "mobileChipsArea",
                     "mobileSuggestions", "mobileAutocomplete",
                     "mobileAutocompleteHeader", "mobileAutocompleteList",
                     "mobileDatePicker", "mobileDatePickerLabel", "mobileDatePickerInput",
                     "mobileLoading", "mobileResultHeader", "mobileResultCount", "mobileResults"]
  static values = { url: String, autocompleteUrl: String }

  connect() {
    this.filters = []
    this._hideTimeout = null
    this._activePrefix = null // "from", "in", etc.
    this._autocompleteCache = {}
    this._searchDebounce = null
    this._searchSeq = 0 // sequence counter to discard stale responses
    this._storageKey = this._buildStorageKey()

    // Restore saved search state
    this._restoreState()

    // After frame swap, rebuild key and restore saved state for the new channel
    // State is already saved to sessionStorage by search() after each query completes
    this._onFrameLoad = (e) => {
      if (e.target.id !== "main-content") return
      const newKey = this._buildStorageKey()
      if (newKey === this._storageKey) return
      this._storageKey = newKey
      // Use setTimeout so Stimulus MutationObserver connects new targets first
      setTimeout(() => {
        this._resetUI()
        this._restoreState()
      }, 0)
    }
    document.addEventListener("turbo:frame-load", this._onFrameLoad)
  }

  disconnect() {
    if (this._scrollHandler) {
      this.sidebarResultsTarget?.removeEventListener("scroll", this._scrollHandler)
    }
    if (this._onFrameLoad) document.removeEventListener("turbo:frame-load", this._onFrameLoad)
    clearTimeout(this._scrollSaveTimer)
    clearTimeout(this._hideTimeout)
    clearTimeout(this._searchDebounce)
    clearTimeout(this._mobileSearchDebounce)
  }

  // -- Dropdowns visibility --

  focusInput() {
    this.queryTarget.focus()
  }

  showSuggestions() {
    if (this._activePrefix) return // autocomplete is showing
    this._hideAll()
    this.suggestionsTarget.classList.remove("hidden")
    this._updateBarWidth(true)
  }

  scheduleSuggestionsHide() {
    this._hideTimeout = setTimeout(() => {
      this._hideAll()
      this._updateBarWidth(false)
    }, 150)
  }

  _updateBarWidth(focused) {
    if (!this.hasSearchBarTarget) return
    if (focused || this.filters.length > 0 || this._activePrefix) {
      this.searchBarTarget.style.width = "420px"
    } else {
      this.searchBarTarget.style.width = "200px"
    }
  }

  keepSuggestions(e) {
    e.preventDefault()
    clearTimeout(this._hideTimeout)
  }

  _hideAll() {
    this.suggestionsTarget.classList.add("hidden")
    if (this.hasAutocompleteTarget) this.autocompleteTarget.classList.add("hidden")
    if (this.hasDatePickerTarget) this.datePickerTarget.classList.add("hidden")
  }

  // -- Filter insertion --

  insertFilter(e) {
    e.preventDefault()
    const type = e.currentTarget.dataset.filterType
    this._hideAll()

    // Date filters → show date picker
    if (["before", "after", "on"].includes(type)) {
      this._activePrefix = type
      this.datePickerLabelTarget.textContent = type.charAt(0).toUpperCase() + type.slice(1) + " date"
      this.datePickerInputTarget.value = ""
      this.datePickerTarget.classList.remove("hidden")
      this.datePickerInputTarget.focus()
      return
    }

    // Pinned → just add as chip directly
    if (type === "pinned") {
      this.filters.push({ type: "pinned", value: "true", label: "pinned" })
      this._renderChips()
      this.queryTarget.focus()
      this._debouncedSearch(0)
      return
    }

    // "has" → show simple options inline
    if (type === "has") {
      this._activePrefix = "has"
      this._showHasOptions()
      return
    }

    // from/in → show autocomplete
    this._activePrefix = type
    this.queryTarget.value = ""
    this.queryTarget.placeholder = type === "from" ? "Search users..." : "Search channels..."
    this.queryTarget.focus()
    this._fetchAutocomplete("")
  }

  _showHasOptions() {
    this.autocompleteHeaderTarget.textContent = "Has type"
    const options = [
      { value: "file", label: "File", icon: "📎" },
      { value: "image", label: "Image", icon: "🖼" },
      { value: "link", label: "Link", icon: "🔗" }
    ]
    this.autocompleteListTarget.innerHTML = options.map(o => `
      <button type="button" data-action="mousedown->message-search#selectAutocomplete" data-autocomplete-value="${o.value}" data-autocomplete-label="has: ${o.label}"
              class="w-full flex items-center gap-3 px-3 py-2 hover:bg-gray-800 text-left cursor-pointer">
        <span class="w-5 text-center">${o.icon}</span>
        <span class="text-sm text-gray-200">${o.label}</span>
      </button>
    `).join("")
    this.autocompleteTarget.classList.remove("hidden")
  }

  // -- Date picker --

  selectDate() {
    const val = this.datePickerInputTarget.value
    if (!val || !this._activePrefix) return
    this.filters.push({ type: this._activePrefix, value: val, label: `${this._activePrefix}: ${val}` })
    this._activePrefix = null
    this._renderChips()
    this._hideAll()
    this.queryTarget.placeholder = "Search"
    this.queryTarget.focus()
    this._debouncedSearch(0)
  }

  // -- Autocomplete fetching --

  async _fetchAutocomplete(query) {
    if (!this.autocompleteUrlValue || !this._activePrefix) return
    const type = this._activePrefix

    const headerText = type === "from" ? "From User" : "In Channel"
    this.autocompleteHeaderTarget.textContent = headerText

    const cacheKey = `${type}:${query}`
    if (this._autocompleteCache[cacheKey]) {
      this._renderAutocompleteResults(this._autocompleteCache[cacheKey], type)
      return
    }

    try {
      const url = `${this.autocompleteUrlValue}?type=${type}&q=${encodeURIComponent(query)}`
      const resp = await fetch(url, { headers: { "Accept": "application/json" } })
      const data = await resp.json()
      this._autocompleteCache[cacheKey] = data
      if (this._activePrefix === type) {
        this._renderAutocompleteResults(data, type)
      }
    } catch (e) {
      // Silently fail
    }
  }

  _renderAutocompleteResults(data, type) {
    if (!data.length) {
      this.autocompleteListTarget.innerHTML = '<div class="px-3 py-2 text-sm text-gray-500">No results</div>'
      this.autocompleteTarget.classList.remove("hidden")
      return
    }

    if (type === "from") {
      this.autocompleteListTarget.innerHTML = data.map(item => `
        <button type="button" data-action="mousedown->message-search#selectAutocomplete"
                data-autocomplete-value="${this._escapeAttr(item.value)}"
                data-autocomplete-label="from: ${this._escapeAttr(item.name)}"
                class="w-full flex items-center gap-2.5 px-3 py-1.5 hover:bg-gray-800 text-left cursor-pointer">
          ${item.avatar
            ? `<img src="${this._escapeAttr(item.avatar)}" class="w-6 h-6 rounded-full object-cover shrink-0">`
            : `<div class="w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold text-white shrink-0" style="background-color:${item.color || '#1e1c1b'}">${this._escapeHtml(item.name[0].toUpperCase())}</div>`
          }
          <div class="min-w-0">
            <div class="text-sm text-white font-medium truncate">${this._escapeHtml(item.name)}</div>
            <div class="text-xs text-gray-500 truncate">${this._escapeHtml(item.subtitle)}</div>
          </div>
        </button>
      `).join("")
    } else if (type === "in") {
      this.autocompleteListTarget.innerHTML = data.map(item => `
        <button type="button" data-action="mousedown->message-search#selectAutocomplete"
                data-autocomplete-value="${this._escapeAttr(item.value)}"
                data-autocomplete-label="in: #${this._escapeAttr(item.name)}"
                class="w-full flex items-center gap-2.5 px-3 py-1.5 hover:bg-gray-800 text-left cursor-pointer">
          <span class="text-gray-400 text-lg shrink-0">${item.encrypted ? '🔒' : '#'}</span>
          <span class="text-sm text-gray-200">${this._escapeHtml(item.name)}</span>
        </button>
      `).join("")
    }
    this.autocompleteTarget.classList.remove("hidden")
  }

  selectAutocomplete(e) {
    e.preventDefault()
    const value = e.currentTarget.dataset.autocompleteValue
    const label = e.currentTarget.dataset.autocompleteLabel
    const type = this._activePrefix

    this.filters.push({ type, value, label })
    this._activePrefix = null
    this._renderChips()
    this._hideAll()
    this.queryTarget.value = ""
    this.queryTarget.placeholder = "Search"
    this.queryTarget.focus()
    this._debouncedSearch(0)
  }

  // -- Input handling --

  onInput() {
    const val = this.queryTarget.value

    if (this._activePrefix) {
      // Typing autocomplete query for from:/in:
      if (["from", "in"].includes(this._activePrefix)) {
        this._fetchAutocomplete(val.trim())
      }
      return
    }

    // Detect if user typed a filter prefix
    const prefixMatch = val.match(/^(from|in|has|before|after|on|pinned|mentions):$/i)
    if (prefixMatch) {
      const type = prefixMatch[1].toLowerCase()
      this.queryTarget.value = ""
      // Trigger the same flow as clicking a suggestion
      this.insertFilter({ preventDefault: () => {}, currentTarget: { dataset: { filterType: type } } })
      return
    }

    // Keep suggestions visible while typing so filters remain accessible
    this.suggestionsTarget.classList.remove("hidden")

    // Live search as user types
    this._debouncedSearch()
  }

  _debouncedSearch(delay = 350) {
    clearTimeout(this._searchDebounce)
    this._searchDebounce = setTimeout(() => this.search(), delay)
  }

  onKeydown(e) {
    if (e.key === "Enter") {
      e.preventDefault()
      if (this._activePrefix && this.queryTarget.value.trim()) {
        // Commit current autocomplete as free-text filter
        const val = this.queryTarget.value.trim()
        this.filters.push({ type: this._activePrefix, value: val, label: `${this._activePrefix}: ${val}` })
        this._activePrefix = null
        this.queryTarget.value = ""
        this.queryTarget.placeholder = "Search"
        this._renderChips()
        this._hideAll()
      } else if (!this._activePrefix) {
        this._hideAll()
        this.search()
      }
    } else if (e.key === "Escape") {
      if (this._activePrefix) {
        this._activePrefix = null
        this.queryTarget.value = ""
        this.queryTarget.placeholder = "Search"
        this._hideAll()
      } else {
        this._hideAll()
        this.queryTarget.blur()
      }
    } else if (e.key === "Backspace" && this.queryTarget.value === "") {
      if (this._activePrefix) {
        this._activePrefix = null
        this.queryTarget.placeholder = "Search"
        this._hideAll()
      } else if (this.filters.length > 0) {
        this.filters.pop()
        this._renderChips()
      }
    }
  }

  // -- Chip rendering --

  removeChip(e) {
    e.preventDefault()
    e.stopPropagation()
    const idx = parseInt(e.currentTarget.dataset.chipIndex)
    this.filters.splice(idx, 1)
    this._renderChips()
    this.queryTarget.focus()
    this._debouncedSearch(0)
  }

  _renderChips() {
    this.chipsAreaTarget.innerHTML = this.filters.map((f, i) => `
      <span class="inline-flex items-center gap-0.5 bg-accent/20 text-accent-light text-[11px] font-medium pl-1.5 pr-0.5 py-0 rounded shrink-0 leading-5 max-w-[160px]">
        <span class="truncate">${this._escapeHtml(f.label || `${f.type}: ${f.value}`)}</span>
        <button type="button" data-action="mousedown->message-search#removeChip" data-chip-index="${i}" class="hover:text-white cursor-pointer px-0.5 shrink-0">&times;</button>
      </span>
    `).join("")
    this._updateBarWidth(document.activeElement === this.queryTarget)
  }

  // -- Search execution --

  async search() {
    const params = new URLSearchParams()
    const searchText = this.queryTarget.value.trim()

    for (const f of this.filters) {
      // Use append so multiple filters of the same type are sent as arrays
      if (["from", "in", "has", "mentions"].includes(f.type)) {
        params.append(`${f.type}[]`, f.value)
      } else {
        params.set(f.type, f.value)
      }
    }
    if (searchText) params.set("q", searchText)

    if (!params.toString()) {
      // Nothing to search — hide sidebar if open
      if (!this.sidebarTarget.classList.contains("hidden")) {
        this.sidebarTarget.classList.add("hidden")
        this.sidebarResultsTarget.innerHTML = ""
        this._clearSavedState()
      }
      return
    }

    const seq = ++this._searchSeq

    // Show sidebar
    this.sidebarTarget.classList.remove("hidden")
    this.sidebarLoadingTarget.classList.remove("hidden")
    this.resultCountTarget.textContent = "Searching..."

    try {
      const response = await fetch(`${this.urlValue}?${params}`, {
        headers: { "Accept": "text/html" }
      })
      if (seq !== this._searchSeq) return // stale response

      const html = await response.text()
      if (seq !== this._searchSeq) return

      this.sidebarResultsTarget.innerHTML = html
      const count = this.sidebarResultsTarget.querySelectorAll(".search-result").length
      const meta = this.sidebarResultsTarget.querySelector(".search-meta")
      const total = meta?.dataset?.total
      if (total && parseInt(total) > count) {
        this.resultCountTarget.textContent = `${count} of ${total} Results`
      } else {
        this.resultCountTarget.textContent = count > 0 ? `${count} Result${count !== 1 ? "s" : ""}` : "No Results"
      }
      this._saveState()
      this._trackScroll()
    } catch (e) {
      if (seq !== this._searchSeq) return
      this.sidebarResultsTarget.innerHTML = '<div class="text-center text-red-400 py-8 text-sm">Search failed</div>'
      this.resultCountTarget.textContent = "Error"
    } finally {
      if (seq === this._searchSeq) {
        this.sidebarLoadingTarget.classList.add("hidden")
      }
    }
  }

  async loadMore(e) {
    const btn = e.currentTarget
    const nextPage = btn.dataset.page
    btn.textContent = "Loading..."
    btn.disabled = true

    const params = new URLSearchParams()
    const searchText = this.queryTarget.value.trim()

    for (const f of this.filters) {
      if (["from", "in", "has", "mentions"].includes(f.type)) {
        params.append(`${f.type}[]`, f.value)
      } else {
        params.set(f.type, f.value)
      }
    }
    if (searchText) params.set("q", searchText)
    params.set("page", nextPage)

    try {
      const response = await fetch(`${this.urlValue}?${params}`, {
        headers: { "Accept": "text/html" }
      })
      const html = await response.text()

      // Remove the current "Load more" button and meta
      btn.closest("div")?.remove()
      this.sidebarResultsTarget.querySelector(".search-meta")?.remove()

      // Append new results
      const temp = document.createElement("div")
      temp.innerHTML = html
      // Remove the "no results" message if present
      const noResults = temp.querySelector(".text-center.text-gray-500")
      if (noResults && temp.querySelectorAll(".search-result").length === 0) return

      this.sidebarResultsTarget.insertAdjacentHTML("beforeend", html)

      const totalCount = this.sidebarResultsTarget.querySelectorAll(".search-result").length
      const meta = this.sidebarResultsTarget.querySelector(".search-meta")
      const total = meta?.dataset?.total
      this.resultCountTarget.textContent = total ? `${totalCount} of ${total} Results` : `${totalCount} Results`
      this._saveState()
    } catch (e) {
      btn.textContent = "Load more results"
      btn.disabled = false
    }
  }

  _trackScroll() {
    // Debounced scroll save on results panel
    if (this._scrollHandler) {
      this.sidebarResultsTarget.removeEventListener("scroll", this._scrollHandler)
    }
    this._scrollHandler = () => {
      clearTimeout(this._scrollSaveTimer)
      this._scrollSaveTimer = setTimeout(() => this._saveState(), 200)
    }
    this.sidebarResultsTarget.addEventListener("scroll", this._scrollHandler, { passive: true })
  }

  closeSidebar() {
    this.clearSearch()
  }

  clearSearch() {
    this.filters = []
    this.queryTarget.value = ""
    this.queryTarget.placeholder = "Search"
    this._activePrefix = null
    this._renderChips()
    this._hideAll()
    this.sidebarTarget.classList.add("hidden")
    this.sidebarResultsTarget.innerHTML = ""
    this._clearSavedState()
  }

  // -- Jump to message --

  jumpToMessage(e) {
    const row = e.currentTarget
    const messageId = row.dataset.messageId
    const channelId = row.dataset.channelId
    const serverId = row.dataset.serverId

    const currentChannelId = this.element.dataset.currentChannelId
    if (channelId && currentChannelId && channelId !== currentChannelId) {
      sessionStorage.setItem("jump_to_message", messageId)
      const sidebarLink = document.querySelector(`a[data-channel-id="${channelId}"]`)
      if (sidebarLink) {
        sidebarLink.click()
      } else if (serverId) {
        Turbo.visit(`/servers/${serverId}/channels/${channelId}`)
      }
      return
    }

    const el = document.querySelector(`[data-message-id="${messageId}"]`)
    if (el) {
      el.scrollIntoView({ behavior: "smooth", block: "center" })
      el.classList.add("bg-accent/20")
      setTimeout(() => el.classList.remove("bg-accent/20"), 2000)
    } else {
      sessionStorage.setItem("jump_to_message", messageId)
    }
  }

  // -- Mobile search --

  openMobileSearch() {
    this.mobileOverlayTarget.classList.remove("hidden")
    this._mobileActivePrefix = null
    this.mobileLoadingTarget.classList.add("hidden")

    // Restore saved mobile search state if available
    const saved = this._savedState
    if (saved && saved.mobile && saved.resultsHtml) {
      this._mobileFilters = saved.filters || []
      this._renderMobileChips()
      this.mobileQueryTarget.value = saved.query || ""
      this.mobileResultsTarget.innerHTML = saved.resultsHtml
      this.mobileResultCountTarget.textContent = saved.resultCount || "Results"
      this.mobileResultHeaderTarget.classList.remove("hidden")
      this.mobileSuggestionsTarget.classList.add("hidden")
      this._hideMobileDropdowns()
      this._trackMobileScroll()
      if (saved.scrollTop) {
        requestAnimationFrame(() => {
          this.mobileResultsTarget.scrollTop = saved.scrollTop
        })
      }
      this._savedState = null // consumed
    } else {
      this._mobileFilters = []
      this.mobileQueryTarget.value = ""
      this.mobileChipsAreaTarget.innerHTML = ""
      this._hideMobileDropdowns()
      this.mobileSuggestionsTarget.classList.remove("hidden")
      this.mobileResultHeaderTarget.classList.add("hidden")
      this.mobileResultsTarget.innerHTML = ""
    }
    setTimeout(() => this.mobileQueryTarget.focus(), 100)
  }

  closeMobileSearch() {
    this.mobileOverlayTarget.classList.add("hidden")
    this._mobileActivePrefix = null
    this._mobileFilters = []
    this._clearSavedState()
  }

  insertMobileFilter(e) {
    const type = e.currentTarget.dataset.filterType
    this._hideMobileDropdowns()

    if (["before", "after", "on"].includes(type)) {
      this._mobileActivePrefix = type
      this.mobileDatePickerLabelTarget.textContent = type.charAt(0).toUpperCase() + type.slice(1) + " date"
      this.mobileDatePickerInputTarget.value = ""
      this.mobileDatePickerTarget.classList.remove("hidden")
      this.mobileDatePickerInputTarget.focus()
      return
    }

    if (type === "pinned") {
      if (!this._mobileFilters) this._mobileFilters = []
      this._mobileFilters.push({ type: "pinned", value: "true", label: "pinned" })
      this._renderMobileChips()
      this.mobileQueryTarget.focus()
      this._debouncedMobileSearch(0)
      return
    }

    if (type === "has") {
      this._mobileActivePrefix = "has"
      this._showMobileHasOptions()
      return
    }

    this._mobileActivePrefix = type
    this.mobileQueryTarget.value = ""
    this.mobileQueryTarget.placeholder = type === "from" ? "Search users..." : "Search channels..."
    this.mobileQueryTarget.focus()
    this._fetchMobileAutocomplete("")
  }

  _showMobileHasOptions() {
    this.mobileAutocompleteHeaderTarget.textContent = "Has type"
    const options = [
      { value: "file", label: "File", icon: "📎" },
      { value: "image", label: "Image", icon: "🖼" },
      { value: "link", label: "Link", icon: "🔗" }
    ]
    this.mobileAutocompleteListTarget.innerHTML = options.map(o => `
      <button type="button" data-action="click->message-search#selectMobileAutocomplete" data-autocomplete-value="${o.value}" data-autocomplete-label="has: ${o.label}"
              class="w-full flex items-center gap-3 px-3 py-2.5 hover:bg-gray-700 text-left cursor-pointer">
        <span class="w-5 text-center">${o.icon}</span>
        <span class="text-sm text-gray-200">${o.label}</span>
      </button>
    `).join("")
    this.mobileAutocompleteTarget.classList.remove("hidden")
  }

  selectMobileDate() {
    const val = this.mobileDatePickerInputTarget.value
    if (!val || !this._mobileActivePrefix) return
    if (!this._mobileFilters) this._mobileFilters = []
    this._mobileFilters.push({ type: this._mobileActivePrefix, value: val, label: `${this._mobileActivePrefix}: ${val}` })
    this._mobileActivePrefix = null
    this._renderMobileChips()
    this._hideMobileDropdowns()
    this.mobileQueryTarget.placeholder = "Search messages..."
    this.mobileQueryTarget.focus()
    this._debouncedMobileSearch(0)
  }

  selectMobileAutocomplete(e) {
    const value = e.currentTarget.dataset.autocompleteValue
    const label = e.currentTarget.dataset.autocompleteLabel
    const type = this._mobileActivePrefix

    if (!this._mobileFilters) this._mobileFilters = []
    this._mobileFilters.push({ type, value, label })
    this._mobileActivePrefix = null
    this._renderMobileChips()
    this._hideMobileDropdowns()
    this.mobileQueryTarget.value = ""
    this.mobileQueryTarget.placeholder = "Search messages..."
    this.mobileQueryTarget.focus()
    this._debouncedMobileSearch(0)
  }

  onMobileInput() {
    const val = this.mobileQueryTarget.value

    if (this._mobileActivePrefix) {
      if (["from", "in"].includes(this._mobileActivePrefix)) {
        this._fetchMobileAutocomplete(val.trim())
      }
      return
    }

    const prefixMatch = val.match(/^(from|in|has|before|after|on|pinned|mentions):$/i)
    if (prefixMatch) {
      const type = prefixMatch[1].toLowerCase()
      this.mobileQueryTarget.value = ""
      this.insertMobileFilter({ currentTarget: { dataset: { filterType: type } } })
      return
    }

    // Keep suggestions visible while typing so filters remain accessible
    this.mobileSuggestionsTarget.classList.remove("hidden")

    // Live search as user types
    this._debouncedMobileSearch()
  }

  _debouncedMobileSearch(delay = 350) {
    clearTimeout(this._mobileSearchDebounce)
    this._mobileSearchDebounce = setTimeout(() => this.mobileSearch(), delay)
  }

  onMobileKeydown(e) {
    if (e.key === "Enter") {
      e.preventDefault()
      if (this._mobileActivePrefix && this.mobileQueryTarget.value.trim()) {
        const val = this.mobileQueryTarget.value.trim()
        if (!this._mobileFilters) this._mobileFilters = []
        this._mobileFilters.push({ type: this._mobileActivePrefix, value: val, label: `${this._mobileActivePrefix}: ${val}` })
        this._mobileActivePrefix = null
        this.mobileQueryTarget.value = ""
        this.mobileQueryTarget.placeholder = "Search messages..."
        this._renderMobileChips()
        this._hideMobileDropdowns()
      } else if (!this._mobileActivePrefix) {
        this._hideMobileDropdowns()
        this.mobileSearch()
      }
    } else if (e.key === "Backspace" && this.mobileQueryTarget.value === "") {
      if (this._mobileActivePrefix) {
        this._mobileActivePrefix = null
        this.mobileQueryTarget.placeholder = "Search messages..."
        this._hideMobileDropdowns()
      } else if (this._mobileFilters && this._mobileFilters.length > 0) {
        this._mobileFilters.pop()
        this._renderMobileChips()
      }
    }
  }

  async mobileSearch() {
    const params = new URLSearchParams()
    const searchText = this.mobileQueryTarget.value.trim()
    const filters = this._mobileFilters || []

    for (const f of filters) {
      if (["from", "in", "has", "mentions"].includes(f.type)) {
        params.append(`${f.type}[]`, f.value)
      } else {
        params.set(f.type, f.value)
      }
    }
    if (searchText) params.set("q", searchText)
    if (!params.toString()) return

    this.mobileLoadingTarget.classList.remove("hidden")
    this.mobileResultHeaderTarget.classList.add("hidden")
    this.mobileResultsTarget.innerHTML = ""

    try {
      const response = await fetch(`${this.urlValue}?${params}`, {
        headers: { "Accept": "text/html" }
      })
      const html = await response.text()

      this.mobileResultsTarget.innerHTML = html
      const count = this.mobileResultsTarget.querySelectorAll(".search-result").length
      const meta = this.mobileResultsTarget.querySelector(".search-meta")
      const total = meta?.dataset?.total
      if (total && parseInt(total) > count) {
        this.mobileResultCountTarget.textContent = `${count} of ${total} Results`
      } else {
        this.mobileResultCountTarget.textContent = count > 0 ? `${count} Result${count !== 1 ? "s" : ""}` : "No Results"
      }
      this.mobileResultHeaderTarget.classList.remove("hidden")
      this.mobileSuggestionsTarget.classList.add("hidden")
      this._saveMobileState()
      this._trackMobileScroll()
    } catch (e) {
      this.mobileResultsTarget.innerHTML = '<div class="text-center text-red-400 py-8 text-sm">Search failed</div>'
      this.mobileResultCountTarget.textContent = "Error"
      this.mobileResultHeaderTarget.classList.remove("hidden")
    } finally {
      this.mobileLoadingTarget.classList.add("hidden")
    }
  }

  removeMobileChip(e) {
    e.preventDefault()
    e.stopPropagation()
    const idx = parseInt(e.currentTarget.dataset.chipIndex)
    if (this._mobileFilters) this._mobileFilters.splice(idx, 1)
    this._renderMobileChips()
    this.mobileQueryTarget.focus()
    this._debouncedMobileSearch(0)
  }

  _renderMobileChips() {
    const filters = this._mobileFilters || []
    this.mobileChipsAreaTarget.innerHTML = filters.map((f, i) => `
      <span class="inline-flex items-center gap-0.5 bg-accent/20 text-accent-light text-[11px] font-medium pl-1.5 pr-0.5 py-0 rounded shrink-0 leading-5">
        ${this._escapeHtml(f.label || `${f.type}: ${f.value}`)}
        <button type="button" data-action="click->message-search#removeMobileChip" data-chip-index="${i}" class="hover:text-white cursor-pointer px-0.5">&times;</button>
      </span>
    `).join("")
  }

  _hideMobileDropdowns() {
    if (this.hasMobileSuggestionsTarget) this.mobileSuggestionsTarget.classList.add("hidden")
    if (this.hasMobileAutocompleteTarget) this.mobileAutocompleteTarget.classList.add("hidden")
    if (this.hasMobileDatePickerTarget) this.mobileDatePickerTarget.classList.add("hidden")
  }

  async _fetchMobileAutocomplete(query) {
    if (!this.autocompleteUrlValue || !this._mobileActivePrefix) return
    const type = this._mobileActivePrefix

    const headerText = type === "from" ? "From User" : "In Channel"
    this.mobileAutocompleteHeaderTarget.textContent = headerText

    const cacheKey = `${type}:${query}`
    if (this._autocompleteCache[cacheKey]) {
      this._renderMobileAutocompleteResults(this._autocompleteCache[cacheKey], type)
      return
    }

    try {
      const url = `${this.autocompleteUrlValue}?type=${type}&q=${encodeURIComponent(query)}`
      const resp = await fetch(url, { headers: { "Accept": "application/json" } })
      const data = await resp.json()
      this._autocompleteCache[cacheKey] = data
      if (this._mobileActivePrefix === type) {
        this._renderMobileAutocompleteResults(data, type)
      }
    } catch (e) {
      // Silently fail
    }
  }

  _renderMobileAutocompleteResults(data, type) {
    if (!data.length) {
      this.mobileAutocompleteListTarget.innerHTML = '<div class="px-3 py-2 text-sm text-gray-500">No results</div>'
      this.mobileAutocompleteTarget.classList.remove("hidden")
      return
    }

    if (type === "from") {
      this.mobileAutocompleteListTarget.innerHTML = data.map(item => `
        <button type="button" data-action="click->message-search#selectMobileAutocomplete"
                data-autocomplete-value="${this._escapeAttr(item.value)}"
                data-autocomplete-label="from: ${this._escapeAttr(item.name)}"
                class="w-full flex items-center gap-2.5 px-3 py-2 hover:bg-gray-700 text-left cursor-pointer">
          ${item.avatar
            ? `<img src="${this._escapeAttr(item.avatar)}" class="w-7 h-7 rounded-full object-cover shrink-0">`
            : `<div class="w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold text-white shrink-0" style="background-color:${item.color || '#1e1c1b'}">${this._escapeHtml(item.name[0].toUpperCase())}</div>`
          }
          <div class="min-w-0">
            <div class="text-sm text-white font-medium truncate">${this._escapeHtml(item.name)}</div>
            <div class="text-xs text-gray-500 truncate">${this._escapeHtml(item.subtitle)}</div>
          </div>
        </button>
      `).join("")
    } else if (type === "in") {
      this.mobileAutocompleteListTarget.innerHTML = data.map(item => `
        <button type="button" data-action="click->message-search#selectMobileAutocomplete"
                data-autocomplete-value="${this._escapeAttr(item.value)}"
                data-autocomplete-label="in: #${this._escapeAttr(item.name)}"
                class="w-full flex items-center gap-2.5 px-3 py-2 hover:bg-gray-700 text-left cursor-pointer">
          <span class="text-gray-400 text-lg shrink-0">${item.encrypted ? '🔒' : '#'}</span>
          <span class="text-sm text-gray-200">${this._escapeHtml(item.name)}</span>
        </button>
      `).join("")
    }
    this.mobileAutocompleteTarget.classList.remove("hidden")
  }

  // -- State persistence --

  _buildStorageKey() {
    // Controller may be on layout wrapper — look inside turbo frame for channel/conversation context
    const frame = document.getElementById("main-content")
    const scope = frame || this.element
    const channelEl = scope.querySelector("[data-current-channel-id]")
    if (channelEl) return `search:ch:${channelEl.dataset.currentChannelId}`
    const convEl = scope.querySelector("[data-dm-message-form-conversation-id-value]")
    if (convEl) return `search:dm:${convEl.dataset.dmMessageFormConversationIdValue}`
    return null
  }

  _saveState() {
    if (!this._storageKey) return
    // Only save if there's an active search (filters or query text)
    const hasSearch = this.filters.length > 0 || (this.hasQueryTarget && this.queryTarget.value.trim())
    if (!hasSearch) return
    const state = {
      filters: this.filters,
      query: this.queryTarget.value,
      resultsHtml: this.sidebarResultsTarget.innerHTML,
      resultCount: this.resultCountTarget.textContent,
      sidebarOpen: !this.sidebarTarget.classList.contains("hidden"),
      scrollTop: this.sidebarResultsTarget.scrollTop
    }
    try {
      sessionStorage.setItem(this._storageKey, JSON.stringify(state))
    } catch (e) { /* quota exceeded — ignore */ }
  }

  _restoreState() {
    if (!this._storageKey) return
    let state
    try {
      const raw = sessionStorage.getItem(this._storageKey)
      if (!raw) return
      state = JSON.parse(raw)
    } catch (e) { return }

    if (!state || !state.filters) return
    this._savedState = state

    // Restore desktop state immediately (mobile restored on open)
    if (!state.mobile) {
      this.filters = state.filters
      this._renderChips()
      if (state.query && this.hasQueryTarget) this.queryTarget.value = state.query
      // Ensure bar stays expanded with chips (target may not be ready at connect)
      requestAnimationFrame(() => this._updateBarWidth(false))

      if (state.sidebarOpen && state.resultsHtml && this.hasSidebarTarget) {
        this.sidebarTarget.classList.remove("hidden")
        this.sidebarResultsTarget.innerHTML = state.resultsHtml
        if (this.hasResultCountTarget) this.resultCountTarget.textContent = state.resultCount || "Results"
        this._trackScroll()
        if (state.scrollTop) {
          requestAnimationFrame(() => {
            this.sidebarResultsTarget.scrollTop = state.scrollTop
          })
        }
      }
    }
  }

  _saveMobileState() {
    if (!this._storageKey) return
    const state = {
      mobile: true,
      filters: this._mobileFilters || [],
      query: this.mobileQueryTarget.value,
      resultsHtml: this.mobileResultsTarget.innerHTML,
      resultCount: this.mobileResultCountTarget.textContent,
      scrollTop: this.mobileResultsTarget.scrollTop
    }
    try {
      sessionStorage.setItem(this._storageKey, JSON.stringify(state))
    } catch (e) { /* quota exceeded */ }
  }

  _trackMobileScroll() {
    if (this._mobileScrollHandler) {
      this.mobileResultsTarget.removeEventListener("scroll", this._mobileScrollHandler)
    }
    this._mobileScrollHandler = () => {
      clearTimeout(this._mobileScrollSaveTimer)
      this._mobileScrollSaveTimer = setTimeout(() => this._saveMobileState(), 200)
    }
    this.mobileResultsTarget.addEventListener("scroll", this._mobileScrollHandler, { passive: true })
  }

  _resetUI() {
    this.filters = []
    this._activePrefix = null
    if (this.hasQueryTarget) {
      this.queryTarget.value = ""
      this.queryTarget.placeholder = "Search"
    }
    if (this.hasChipsAreaTarget) this.chipsAreaTarget.innerHTML = ""
    if (this.hasSidebarTarget) this.sidebarTarget.classList.add("hidden")
    if (this.hasSidebarResultsTarget) this.sidebarResultsTarget.innerHTML = ""
    this._updateBarWidth(false)
  }

  _clearSavedState() {
    if (!this._storageKey) return
    sessionStorage.removeItem(this._storageKey)
  }

  // -- Helpers --

  _escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }

  _escapeAttr(str) {
    return str.replace(/"/g, "&quot;").replace(/'/g, "&#39;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }
}

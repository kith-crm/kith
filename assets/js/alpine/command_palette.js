import Alpine from "@alpinejs/csp"

Alpine.data("commandPalette", () => ({
  open: false,
  query: "",
  selectedIndex: 0,
  contacts: [],
  loading: false,
  recentSearches: [],

  pages: [
    { type: "page", name: "Dashboard", path: "/dashboard", icon: "home" },
    { type: "page", name: "Contacts", path: "/contacts", icon: "users" },
    { type: "page", name: "Reminders", path: "/reminders/upcoming", icon: "bell" },
    { type: "page", name: "Settings", path: "/users/settings", icon: "cog" },
  ],

  actions: [
    { type: "action", name: "New Contact", path: "/contacts/new", icon: "plus" },
    { type: "action", name: "Trash", path: "/contacts/trash", icon: "trash" },
    { type: "action", name: "Archived", path: "/contacts/archived", icon: "archive" },
  ],

  init() {
    try {
      const stored = localStorage.getItem("kith:recent-searches")
      if (stored) this.recentSearches = JSON.parse(stored)
    } catch (_) {}
  },

  show() {
    this.open = true
    this.query = ""
    this.selectedIndex = 0
    this.contacts = []
    this.loading = false
    this.$nextTick(() => {
      const input = this.$refs.searchInput
      if (input) input.focus()
    })
  },

  close() {
    this.open = false
    this.query = ""
    this.contacts = []
    this.loading = false
  },

  get filteredPages() {
    if (!this.query) return this.pages
    const q = this.query.toLowerCase()
    return this.pages.filter(p => p.name.toLowerCase().includes(q))
  },

  get filteredActions() {
    if (!this.query) return this.actions
    const q = this.query.toLowerCase()
    return this.actions.filter(a => a.name.toLowerCase().includes(q))
  },

  get allItems() {
    const items = []
    if (!this.query && this.recentSearches.length > 0) {
      this.recentSearches.forEach(r => items.push({ ...r, section: "recent" }))
    }
    this.contacts.forEach(c => items.push({ ...c, type: "contact", section: "contacts" }))
    this.filteredPages.forEach(p => items.push({ ...p, section: "pages" }))
    this.filteredActions.forEach(a => items.push({ ...a, section: "actions" }))
    return items.map((item, index) => ({
      ...item,
      sectionStart: index === 0 || items[index - 1].section !== item.section,
    }))
  },

  onInput() {
    this.selectedIndex = 0
    // Dispatch to the LiveView hook for server search
    if (this.query.length >= 2) {
      this.loading = true
      this.$el.dispatchEvent(new CustomEvent("command-palette:search", {
        bubbles: true,
        detail: { query: this.query }
      }))
    } else {
      this.contacts = []
      this.loading = false
    }
  },

  receiveResults(results) {
    this.contacts = results
    this.loading = false
    this.selectedIndex = 0
  },

  onKeydown(event) {
    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.selectedIndex = Math.min(this.selectedIndex + 1, this.allItems.length - 1)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.selectedIndex = Math.max(this.selectedIndex - 1, 0)
    } else if (event.key === "Enter") {
      event.preventDefault()
      this.selectItem(this.selectedIndex)
    } else if (event.key === "Escape") {
      this.close()
    }
  },

  selectItem(index) {
    const item = this.allItems[index]
    if (!item) return

    // Save to recent searches
    if (item.type === "contact") {
      const entry = { type: "contact", name: item.display_name, path: "/contacts/" + item.id, id: item.id }
      this.recentSearches = [entry, ...this.recentSearches.filter(r => r.id !== item.id)].slice(0, 5)
      try { localStorage.setItem("kith:recent-searches", JSON.stringify(this.recentSearches)) } catch(_) {}
    }

    // Navigate
    const path = item.path || (item.type === "contact" ? "/contacts/" + item.id : null)
    if (path) {
      this.close()
      this.$el.dispatchEvent(new CustomEvent("command-palette:navigate", {
        bubbles: true,
        detail: { path }
      }))
    }
  }
}))

// The hidden ISO date and precision flag are the form contract. The ignored
// subtree keeps calendar navigation and focus intact across LiveView validation.
const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
const pad = value => String(value).padStart(2, "0")
const daysInMonth = (month, year) => {
  const date = new Date(0)
  date.setUTCFullYear(year, month + 1, 0)
  return date.getUTCDate()
}

const BirthdatePicker = {
  mounted() {
    this.find = selector => this.el.querySelector(selector)
    this.input = this.find("[data-birthdate]")
    this.flag = this.find("[data-year-unknown-input]")
    this.trigger = this.find("[data-trigger]")
    this.calendar = this.find("[data-calendar]")
    this.unknown = this.find("[data-unknown]")
    this.monthInput = this.find("[data-month]")
    this.yearInput = this.find("[data-year]")
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(this.input.value)
    this.selected = match ? {month: Number(match[2]) - 1, day: Number(match[3]), year: this.unknown.checked ? null : Number(match[1])} : null
    this.month = this.selected?.month ?? new Date().getMonth()
    this.yearInput.value = this.selected?.year ?? ""
    months.forEach((name, index) => {
      const option = document.createElement("option")
      option.value = index
      option.textContent = name
      this.monthInput.append(option)
    })
    for (const day of ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]) {
      const span = document.createElement("span")
      span.className = "birthdate-weekday"
      span.textContent = day
      this.find("[data-weekdays]").append(span)
    }
    this.onClick = event => {
      if (event.target.closest("[data-trigger]")) this.open(this.calendar.hidden)
      if (event.target.closest("[data-prev]")) this.navigate(-1)
      if (event.target.closest("[data-next]")) this.navigate(1)
      if (event.target.closest("[data-clear]")) {
        this.selected = null
        this.unknown.checked = false
        this.yearInput.value = ""
        this.open(false)
        this.commit()
      }
      const day = event.target.closest("[data-day]")
      if (day) {
        this.selected = {month: this.month, day: Number(day.dataset.day), year: this.year()}
        this.commit()
        this.open(false)
        this.trigger.focus()
      }
    }
    this.onChange = event => {
      if (event.target === this.yearInput) event.stopPropagation()
      if (event.target === this.unknown) {
        event.stopPropagation()
        // Never turn the internal placeholder into a user's birth year.
        if (!this.unknown.checked && this.selected && !this.selected.year) this.yearInput.value = ""
        if (this.selected && !this.unknown.checked) this.month = this.selected.month
        this.open(true)
        this.commit()
      }
      if (event.target === this.monthInput) {
        event.stopPropagation()
        this.month = Number(this.monthInput.value)
        this.render()
      }
    }
    this.onInput = event => {
      if (event.target === this.yearInput) {
        event.stopPropagation()
        if (this.selected) this.selected.year = this.year()
        this.commit()
      }
    }
    this.onKey = event => {
      if (event.key === "Escape" && !this.calendar.hidden) {
        event.preventDefault()
        event.stopPropagation()
        this.open(false)
        this.trigger.focus()
      }
    }
    this.onOutside = event => {
      if (!this.el.contains(event.target)) this.open(false)
    }
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("change", this.onChange)
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keydown", this.onKey)
    document.addEventListener("click", this.onOutside)
    this.render()
  },

  year() {
    const value = Number(this.yearInput.value)
    return Number.isInteger(value) && value >= 1 && value <= 9999 ? value : null
  },

  open(value) {
    this.calendar.hidden = !value
    this.trigger.setAttribute("aria-expanded", String(value))
    // Year must remain part of native form validation even with the panel shut.
    if (!value && this.selected && !this.unknown.checked && !this.valid()) this.calendar.hidden = false
    this.trigger.setAttribute("aria-expanded", String(!this.calendar.hidden))
  },

  valid() {
    if (!this.selected) return true
    const year = this.unknown.checked ? 2000 : this.selected.year
    return !!year && this.selected.day <= daysInMonth(this.selected.month, year)
  },

  navigate(delta) {
    this.month = (this.month + delta + 12) % 12
    this.render()
  },

  commit() {
    const selected = this.selected
    const unknown = this.unknown.checked
    if (selected) {
      const year = unknown ? "2000" : selected.year ? String(selected.year).padStart(4, "0") : ""
      this.input.value = `${year}-${pad(selected.month + 1)}-${pad(selected.day)}`
    } else {
      this.input.value = ""
    }
    this.flag.value = String(unknown)
    this.render()
    this.input.dispatchEvent(new Event("input", {bubbles: true}))
  },

  render() {
    const unknown = this.unknown.checked
    const year = this.year()
    const selected = this.selected
    this.monthInput.value = this.month
    this.yearInput.hidden = unknown
    this.yearInput.disabled = unknown
    this.yearInput.required = !unknown && !!selected
    this.yearInput.setCustomValidity(!unknown && selected && !this.valid() ? "Choose a valid birth year and day." : "")
    this.find("[data-label]").textContent = selected
      ? `${months[selected.month]} ${selected.day}${unknown ? "" : selected.year ? `, ${selected.year}` : " · choose year"}`
      : "Choose a date"
    this.find("[data-help]").textContent = unknown ? "Choose a month and day. No year or age will be shown." : "Choose a month, day, and year."
    this.find("[data-calendar-help]").textContent = unknown ? "Month and day only · February 29 is available" : "Full birthdate · year and age will be shown"
    const error = this.find("[data-error]")
    error.hidden = this.valid()
    error.textContent = year ? "This date is not available in that year. Choose another day." : "Choose a birth year or select “Year unknown.”"
    this.find("[data-weekdays]").hidden = unknown || !year
    this.find("[data-choose-year]").hidden = unknown || !!year
    const grid = this.find("[data-days]")
    grid.replaceChildren()
    if (!unknown && !year) return
    const effectiveYear = unknown ? 2000 : year
    // No weekday alignment is meaningful when the year is unknown.
    const date = new Date(0)
    date.setUTCFullYear(effectiveYear, this.month, 1)
    const offset = unknown ? 0 : date.getUTCDay()
    for (let i = 0; i < offset; i++) grid.append(document.createElement("span"))
    for (let day = 1; day <= daysInMonth(this.month, effectiveYear); day++) {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "birthdate-day"
      button.dataset.day = day
      button.textContent = day
      button.setAttribute("aria-label", `${months[this.month]} ${day}${unknown ? "" : `, ${year}`}`)
      button.setAttribute("aria-pressed", String(!!selected && selected.month === this.month && selected.day === day && (unknown || selected.year === year)))
      grid.append(button)
    }
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("change", this.onChange)
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keydown", this.onKey)
    document.removeEventListener("click", this.onOutside)
  },
}

export default BirthdatePicker

import "trix/trix"
import { serializeToContentType } from "trix/core/serialization"

// Decode entities only into a text node; escaped imported HTML never becomes markup.
function loadStoredContent(editor, content) {
  if (/<[a-z!/]/i.test(content)) {
    editor.loadHTML(content)
  } else {
    const text = document.createElement("textarea")
    text.innerHTML = content.replace(/</g, "&lt;").replace(/>/g, "&gt;")
    editor.loadHTML("")
    editor.setSelectedRange([0, 0])
    editor.insertString(text.value)
  }
}

const TrixEditor = {
  mounted() {
    this.editor = this.el.querySelector("trix-editor")
    this.hiddenInput = this.el.querySelector("input[type=hidden]")
    this.toolbar = this.el.querySelector("trix-toolbar")
    // Trix invokes toolbar commands on mousedown. Keyboard activation emits click.
    this.toolbarClickHandler = event => {
      const button = event.target.closest(".note-toolbar-button")
      if (button && event.detail === 0 && !button.disabled) {
        button.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }))
      }
    }
    this.toolbar.addEventListener("click", this.toolbarClickHandler)
    // Let Trix dismiss the link dialog before an enclosing modal sees Escape.
    this.dialogKeyHandler = event => {
      if (event.key === "Escape" && event.target.matches("[data-trix-input]")) event.stopPropagation()
    }
    this.el.addEventListener("keydown", this.dialogKeyHandler)
    this.toolbarObserver = new MutationObserver(() => {
      this.toolbar.querySelectorAll("[data-trix-attribute]").forEach(button => {
        const active = button.dataset.trixAttribute === "href"
          ? this.toolbar.querySelector('[data-trix-dialog="href"]').hasAttribute("data-trix-active")
          : button.hasAttribute("data-trix-active")
        button.setAttribute(button.dataset.trixAttribute === "href" ? "aria-expanded" : "aria-pressed", String(active))
      })
    })
    this.toolbarObserver.observe(this.toolbar, { subtree: true, attributes: true, attributeFilter: ["data-trix-active"] })
    this.serverValue = this.el.dataset.value || ""
    this.changeHandler = () => {
      if (this.loading || !this.editor.editor) return
      const document = this.editor.editor.getDocument()
      // Trix's element.value aliases the input that LiveView may have patched.
      this.hiddenInput.value = document.toString().trim()
        ? serializeToContentType(document, "text/html") : ""
      this.hiddenInput.dispatchEvent(new Event("input", { bubbles: true }))
    }
    this.fileHandler = event => event.preventDefault()
    this.initialize = () => {
      this.loading = true
      loadStoredContent(this.editor.editor, this.serverValue)
      this.hiddenInput.value = this.serverValue
      this.loading = false
    }
    this.editor.addEventListener("trix-change", this.changeHandler)
    this.editor.addEventListener("trix-file-accept", this.fileHandler)
    this.editor.addEventListener("trix-initialize", this.initialize)
    this.form = this.el.closest("form")
    this.submitHandler = () => {
      this.submission = { value: this.hiddenInput.value, document: this.editor.editor.getDocument() }
    }
    this.form?.addEventListener("submit", this.submitHandler, true)
    if (this.editor.editor) this.initialize()
  },

  updated() {
    this.hiddenInput = this.el.querySelector("input[type=hidden]")
    const value = this.el.dataset.value || ""
    // Compare server versions, not the document: unrelated patches must not reset typing.
    if (value !== this.serverValue) {
      const newerCorrection = this.submission && value === this.submission.value &&
        !this.editor.editor.getDocument().isEqualTo(this.submission.document)
      this.serverValue = value
      if (newerCorrection) this.changeHandler()
      else if (this.editor.editor) this.initialize()
    } else {
      this.changeHandler()
    }
    if (this.submission?.value === value) this.submission = null
  },

  destroyed() {
    this.toolbarObserver.disconnect()
    this.el.removeEventListener("keydown", this.dialogKeyHandler)
    this.toolbar.removeEventListener("click", this.toolbarClickHandler)
    this.editor.removeEventListener("trix-change", this.changeHandler)
    this.editor.removeEventListener("trix-file-accept", this.fileHandler)
    this.editor.removeEventListener("trix-initialize", this.initialize)
    this.form?.removeEventListener("submit", this.submitHandler, true)
  }
}

export default TrixEditor

import "trix/trix"

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
    this.serverValue = this.el.dataset.value || ""
    this.changeHandler = () => {
      if (this.loading || !this.editor.editor) return
      this.hiddenInput.value = this.editor.editor.getDocument().toString().trim()
        ? this.editor.value : ""
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
    if (this.editor.editor) this.initialize()
  },

  updated() {
    this.hiddenInput = this.el.querySelector("input[type=hidden]")
    const value = this.el.dataset.value || ""
    // Compare server versions, not the document: unrelated patches must not reset typing.
    if (value !== this.serverValue) {
      this.serverValue = value
      if (this.editor.editor) this.initialize()
    } else {
      this.changeHandler()
    }
  },

  destroyed() {
    this.editor.removeEventListener("trix-change", this.changeHandler)
    this.editor.removeEventListener("trix-file-accept", this.fileHandler)
    this.editor.removeEventListener("trix-initialize", this.initialize)
  }
}

export default TrixEditor

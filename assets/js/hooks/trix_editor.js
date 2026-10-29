import "trix/trix"

// Older notes were entered in a textarea. Their stored text has literal
// newlines and HTML-escaped entities, rather than editor block markup.
// Insert that text through Trix's text API so breaks survive and escaped
// markup stays text. Rich HTML still goes through Trix's sanitizer.
function loadStoredContent(editor, content) {
  if (/<[a-z!/]/i.test(content)) {
    editor.loadHTML(content)
  } else {
    const text = document.createElement("textarea")
    text.innerHTML = content
    editor.loadHTML("")
    editor.insertString(text.value)
  }
}

const TrixEditor = {
  mounted() {
    this.suppressChange = false
    const inputName = this.el.dataset.input
    this.hiddenInput = this.el.querySelector(`input[name="${inputName}"]`)
    this.editor = this.el.querySelector("trix-editor")

    if (!this.editor) return

    // Sync content changes to hidden input
    this.changeHandler = (_event) => {
      if (this.suppressChange) return
      if (this.hiddenInput) {
        this.hiddenInput.value = this.editor.editor.getDocument().toString().trim()
          ? this.editor.innerHTML
          : ""
      }
    }

    this.editor.addEventListener("trix-change", this.changeHandler)

    // Pre-populate if content exists
    const initialContent = this.hiddenInput?.value
    if (initialContent && initialContent.trim() !== "") {
      this.suppressChange = true
      loadStoredContent(this.editor.editor, initialContent)
      this.suppressChange = false
    }
  },

  updated() {
    // When LiveView re-renders, check if we need to update editor content
    const inputName = this.el.dataset.input
    this.hiddenInput = this.el.querySelector(`input[name="${inputName}"]`)
    const newContent = this.hiddenInput?.value || ""
    const currentContent = this.editor?.innerHTML || ""

    if (newContent !== currentContent && this.editor) {
      this.suppressChange = true
      loadStoredContent(this.editor.editor, newContent)
      this.suppressChange = false
    }
  },

  destroyed() {
    if (this.editor && this.changeHandler) {
      this.editor.removeEventListener("trix-change", this.changeHandler)
    }
  }
}

export default TrixEditor

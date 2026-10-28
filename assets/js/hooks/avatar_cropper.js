import Cropper from "cropperjs"

// Only crop coordinates cross the LiveView boundary. The server validates and
// processes the original image, rather than trusting a browser-generated JPEG.
const selectedFiles = new Map()

// LiveView clears the native FileList while starting an auto-upload. Capture
// the selected File before its delegated change handler runs.
export const AvatarUpload = {
  mounted() {
    this.onChange = event => {
      const file = event.target.files?.[0]
      if (file) {
        this.inputId = event.target.id
        selectedFiles.set(this.inputId, file)
      }
    }
    this.el.addEventListener("change", this.onChange, true)
  },
  destroyed() {
    this.el.removeEventListener("change", this.onChange, true)
    if (this.inputId) selectedFiles.delete(this.inputId)
  },
}

const AvatarCropper = {
  mounted() {
    this.image = this.el.querySelector("img")
    this.dialog = this.el.closest("[role=dialog]")
    this.previousFocus = document.activeElement
    this.onClick = event => {
      const zoom = event.target.closest("[data-crop-zoom]")
      if (zoom) this.cropper?.zoom(Number(zoom.dataset.cropZoom))
      if (event.target.closest("[data-crop-reset]")) this.cropper?.reset()
    }
    this.onKey = event => {
      const directions = {ArrowLeft: [10, 0], ArrowRight: [-10, 0], ArrowUp: [0, 10], ArrowDown: [0, -10]}
      if (directions[event.key] && !["INPUT", "BUTTON"].includes(event.target.tagName)) {
        event.preventDefault()
        this.cropper?.move(...directions[event.key])
      }
      if (event.key === "Tab") {
        const controls = [...this.dialog.querySelectorAll("button:not([disabled]), [tabindex='0']")]
        const first = controls[0], last = controls[controls.length - 1]
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
        if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
      }
    }
    this.el.addEventListener("click", this.onClick)
    this.dialog.addEventListener("keydown", this.onKey)
    const canvas = this.el.querySelector("[phx-update=ignore]")
    canvas.tabIndex = 0
    canvas.setAttribute("aria-label", "Move photo with arrow keys")
    this.image.onerror = () => {
      this.error = "This image could not be opened. Choose another image."
      this.el.querySelector("[data-crop-error]").textContent = this.error
      this.ready = false
      this.syncSave()
    }
    let source = this.el.dataset.source
    if (!source) {
      const file = selectedFiles.get(this.el.dataset.fileInput) || document.getElementById(this.el.dataset.fileInput)?.files?.[0]
      if (file) source = this.objectUrl = URL.createObjectURL(file)
    }
    if (!source) { this.image.onerror(); return }
    this.image.src = source
    this.cropper = new Cropper(this.image, {
      aspectRatio: 1,
      viewMode: 1,
      dragMode: "move",
      autoCropArea: 1,
      checkCrossOrigin: false,
      checkOrientation: false,
      background: false,
      ready: () => {
        this.ready = true
        this.el.dataset.ready = "true"
        this.updateCoordinates()
        this.syncSave()
        canvas.focus()
      },
      crop: () => this.updateCoordinates(),
    })
    this.syncSave()
  },
  updated() {
    if (this.ready) {
      this.el.dataset.ready = "true"
      this.updateCoordinates()
    }
    if (this.error) this.el.querySelector("[data-crop-error]").textContent = this.error
    this.syncSave()
  },
  updateCoordinates() {
    if (!this.cropper) return
    const data = this.cropper.getData()
    data.x = Math.max(0, Math.floor(data.x))
    data.y = Math.max(0, Math.floor(data.y))
    data.width = data.height = Math.floor(Math.min(data.width, data.height))
    for (const field of this.el.querySelectorAll("[data-crop-field]")) {
      field.value = data[field.dataset.cropField]
    }
  },
  syncSave() {
    const button = this.dialog.querySelector("[type=submit]")
    button.disabled = !this.ready || this.el.dataset.uploadComplete === "false"
  },
  destroyed() {
    this.cropper?.destroy()
    this.el.removeEventListener("click", this.onClick)
    this.dialog.removeEventListener("keydown", this.onKey)
    this.image.onerror = null
    if (this.objectUrl) URL.revokeObjectURL(this.objectUrl)
    this.previousFocus?.focus()
  },
}
export default AvatarCropper

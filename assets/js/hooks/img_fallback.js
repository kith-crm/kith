// Toggles a distinct "image unavailable" state when a thumbnail's <img> fails
// to load (e.g. the underlying file is missing / an expired presigned URL 404s).
//
// CSP here is `script-src 'self' 'nonce-...'` with no `unsafe-inline`, so an
// inline `onerror=""` attribute is blocked -- this hook is the CSP-safe path.
//
// It sets `data-img-failed` on the hook element; Tailwind `group-data-[img-failed]`
// variants in the markup do the actual show/hide.
const ImgFallback = {
  mounted() {
    this.bind()
  },

  updated() {
    this.bind()
  },

  // Bind (or re-bind, after a LiveView patch swaps the <img> node) the load /
  // error listeners, and catch an image that already errored before we got here.
  bind() {
    const img = this.el.querySelector("img[data-fallback-img]")
    if (!img || img === this.img) {
      if (img && img.complete && img.naturalWidth === 0) this.fail()
      return
    }

    this.img = img
    this.onError = () => this.fail()
    this.onLoad = () => this.el.removeAttribute("data-img-failed")
    img.addEventListener("error", this.onError)
    img.addEventListener("load", this.onLoad)

    if (img.complete && img.naturalWidth === 0) this.fail()
  },

  fail() {
    this.el.setAttribute("data-img-failed", "true")
  },

  destroyed() {
    if (!this.img) return
    this.img.removeEventListener("error", this.onError)
    this.img.removeEventListener("load", this.onLoad)
  },
}

export default ImgFallback

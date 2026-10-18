// Image load-failure handling for <img data-fallback-img> inside the hook root.
//
// CSP here is `script-src 'self' 'nonce-...'` with no `unsafe-inline`, so an
// inline `onerror=""` attribute is blocked -- this hook is the CSP-safe path.
//
// State machine (design B2/B3): "ok" -> first error -> "retrying" (only when
// the root has data-refreshable="true": ask the component for a fresh URL
// once) -> a second error, or a reply saying the URL did not change ->
// "failed". A load at any point -> "ok". The state lives here and is
// re-applied on every LiveView patch, never re-derived from naturalWidth.
// It is exposed as data-img-retrying / data-img-failed on the root; Tailwind
// group-data-[...] variants in the markup do the show/hide.
const ImgFallback = {
  mounted() {
    this.state = "ok"
    this.bind()
  },

  updated() {
    this.bind()
    this.apply()
  },

  destroyed() {
    this.unbind()
  },

  // (Re)bind to the current <img>. A patch can replace the node (e.g. the
  // syncing placeholder turns into the image); listeners on the old node are
  // removed so a late error from it cannot fail the new one (design B4).
  bind() {
    const img = this.el.querySelector("img[data-fallback-img]")
    if (img === this.img) return

    this.unbind()
    this.img = img
    this.state = "ok"
    this.apply()
    if (!img) return

    this.onError = () => this.handleError()
    this.onLoad = () => this.setState("ok")
    img.addEventListener("error", this.onError)
    img.addEventListener("load", this.onLoad)

    // Failed before we were listening (cached 404).
    if (img.complete && img.naturalWidth === 0 && img.getAttribute("src")) this.handleError()
  },

  unbind() {
    if (!this.img) return
    this.img.removeEventListener("error", this.onError)
    this.img.removeEventListener("load", this.onLoad)
    this.img = null
  },

  handleError() {
    if (this.state === "ok" && this.el.dataset.refreshable === "true") {
      this.setState("retrying")
      const img = this.img
      this.pushEventTo(this.el, "refresh_url", {}, (reply) => {
        // A node swap since the push resets state; a late reply is stale.
        if (this.img !== img || this.state !== "retrying") return
        if (!reply || !reply.changed) this.setState("failed")
      })
    } else {
      this.setState("failed")
    }
  },

  setState(state) {
    this.state = state
    this.apply()
  },

  apply() {
    this.el.toggleAttribute("data-img-retrying", this.state === "retrying")
    this.el.toggleAttribute("data-img-failed", this.state === "failed")
  },
}

export default ImgFallback

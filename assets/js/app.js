// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/kith"
import topbar from "../vendor/topbar"

// Custom hooks
import TrixEditor from "./hooks/trix_editor"
import CommandPalette from "./hooks/command_palette"
import ImgFallback from "./hooks/img_fallback"

// Alpine.js (CSP build -- no runtime code generation, compatible with strict Content-Security-Policy)
import Alpine from "@alpinejs/csp"
import "./alpine/sidebar"
import "./alpine/password_strength"
import "./alpine/totp_challenge"
import "./alpine/recovery_codes"
import "./alpine/lightbox"
import "./alpine/dismissible"
import "./alpine/command_palette"
import "./alpine/copy_text"
window.Alpine = Alpine
Alpine.start()

const Hooks = {
  ...colocatedHooks,
  TrixEditor,
  CommandPalette,
  ImgFallback,
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
  dom: {
    onBeforeElUpdated(from, to) {
      // Preserve Alpine.js state during LiveView patches
      if (from._x_dataStack) {
        window.Alpine.clone(from, to)
      }
    }
  }
})

// Show progress bar on live navigation and form submits
// Amber-colored bar with 200ms delay to prevent flash on fast loads
topbar.config({barColors: {0: "#d97706"}, shadowColor: "rgba(0, 0, 0, .1)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(200))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

import Alpine from "@alpinejs/csp";

Alpine.data("copyText", () => ({
  copied: false,
  copyFailed: false,
  copyTimeout: null,
  init() {
    this.clearSensitive = () => {
      if (this.$root.dataset.copySensitive === "true") {
        const input = this.$root.querySelector("input");
        input.value = "";
        input.setAttribute("value", "");
      }
    };
    window.addEventListener("pagehide", this.clearSensitive);
  },
  destroy() {
    clearTimeout(this.copyTimeout);
    window.removeEventListener("pagehide", this.clearSensitive);
  },
  async copy() {
    clearTimeout(this.copyTimeout);
    this.copied = false;
    this.copyFailed = false;

    try {
      await navigator.clipboard.writeText(this.$root.dataset.copyValue ?? this.$root.querySelector("input").value);
      this.copied = true;
      this.copyTimeout = setTimeout(() => (this.copied = false), 2000);
    } catch {
      this.copyFailed = true;
    }
  },
}));

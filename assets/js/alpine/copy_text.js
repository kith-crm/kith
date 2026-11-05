import Alpine from "@alpinejs/csp";

Alpine.data("copyText", () => ({
  copied: false,
  copyFailed: false,
  copyTimeout: null,
  async copy() {
    clearTimeout(this.copyTimeout);
    this.copied = false;
    this.copyFailed = false;

    try {
      await navigator.clipboard.writeText(this.$root.dataset.copyValue);
      this.copied = true;
      this.copyTimeout = setTimeout(() => (this.copied = false), 2000);
    } catch {
      this.copyFailed = true;
    }
  },
}));

import Alpine from "@alpinejs/csp";

Alpine.data("sidebar", () => ({
  sidebarOpen: localStorage.getItem("kith:sidebar") !== "collapsed",
  toggle() {
    this.sidebarOpen = !this.sidebarOpen;
    localStorage.setItem(
      "kith:sidebar",
      this.sidebarOpen ? "expanded" : "collapsed"
    );
  },
}));

Alpine.data("userMenu", () => ({
  userMenu: false,
  toggle() {
    this.userMenu = !this.userMenu;
  },
  close() {
    this.userMenu = false;
  },
}));

Alpine.data("mobileNavigation", () => ({
  open: false,
  toggle() {
    if (this.open) this.dismiss();
    else this.openAndFocus();
  },
  openAndFocus() {
    this.open = true;
    this.$nextTick(() => this.focusFirst());
  },
  close() {
    this.open = false;
  },
  closeIfFocusOutside(event) {
    if (!this.$el.contains(event.relatedTarget)) this.close();
  },
  dismiss() {
    if (!this.open) return;
    this.close();
    this.$refs.trigger.focus();
  },
  items() {
    return [...this.$refs.menu.querySelectorAll('[role="menuitem"]')];
  },
  focusFirst() {
    this.items()[0]?.focus();
  },
  focusLast() {
    this.items().at(-1)?.focus();
  },
  focusNext() {
    this.moveFocus(1);
  },
  focusPrevious() {
    this.moveFocus(-1);
  },
  moveFocus(step) {
    const items = this.items();
    const current = items.indexOf(document.activeElement);
    items[(current + step + items.length) % items.length]?.focus();
  },
}));

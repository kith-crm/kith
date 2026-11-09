export default {
  mounted() {
    this.el.disabled = false;
    this.onChange = () => {
      const option = this.el.selectedOptions[0];
      if (option && option.dataset.allowed === "true") {
        window.liveSocket.js().navigate(option.value);
      }
    };
    this.el.addEventListener("change", this.onChange);
  },
  updated() {
    this.el.disabled = false;
  },
  destroyed() {
    this.el.removeEventListener("change", this.onChange);
  },
};

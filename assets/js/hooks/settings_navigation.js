export default {
  mounted() {
    this.onChange = () => {
      const option = this.el.selectedOptions[0];
      if (option && option.dataset.allowed === "true") {
        window.liveSocket.js().navigate(option.value);
      }
    };
    this.el.addEventListener("change", this.onChange);
  },
  destroyed() {
    this.el.removeEventListener("change", this.onChange);
  },
};

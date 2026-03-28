const ChatScroll = {
  mounted() {
    this.scrollToBottom();
  },

  updated() {
    // Find the last user message and scroll it to the top of the viewport
    const userMessages = this.el.querySelectorAll("[data-role='user']");
    const lastUser = userMessages[userMessages.length - 1];

    if (lastUser) {
      lastUser.scrollIntoView({ behavior: "smooth", block: "start" });
    } else {
      this.scrollToBottom();
    }
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

export default ChatScroll;

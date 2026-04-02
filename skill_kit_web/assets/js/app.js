import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import hljs from "highlight.js";
import mermaid from "mermaid";
import AutoScroll from "./hooks/auto_scroll";
import ChatScroll from "./hooks/chat_scroll";
import MarkdownEditor from "./hooks/markdown_editor";
import InlineThread from "./hooks/inline_thread";
import OnboardingInput from "./hooks/onboarding_input";
import Theme from "./hooks/theme";

// Make available to hooks
window.hljs = hljs;
window.mermaid = mermaid;

mermaid.initialize({
  startOnLoad: false,
  theme: document.documentElement.classList.contains("dark") ? "dark" : "default",
  themeVariables: {
    darkMode: document.documentElement.classList.contains("dark"),
    primaryColor: "rgba(140, 160, 210, 0.3)",
    primaryTextColor: "var(--editor-text)",
    primaryBorderColor: "rgba(140, 160, 210, 0.4)",
    lineColor: "var(--editor-text-muted)",
    secondaryColor: "rgba(140, 160, 210, 0.1)",
    tertiaryColor: "rgba(140, 160, 210, 0.05)",
  },
});

const hooks = {
  AutoScroll,
  ChatScroll,
  InlineThread,
  MarkdownEditor,
  OnboardingInput,
  Theme,
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  hooks,
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();

window.liveSocket = liveSocket;

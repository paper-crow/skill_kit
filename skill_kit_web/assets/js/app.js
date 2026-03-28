import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import AutoScroll from "./hooks/auto_scroll";
import MarkdownEditor from "./hooks/markdown_editor";
import Theme from "./hooks/theme";

const hooks = {
  AutoScroll,
  MarkdownEditor,
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

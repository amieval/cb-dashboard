import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { AssertionGraph } from "./assertion_graph";

const Hooks = {
  AssertionGraph,
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;

// --- BeliefContext hover popups ------------------------------------------
// CSS handles show/hide via :hover/:focus-within, but the popup needs
// `position: fixed` so it can escape ancestor `overflow: hidden`/`auto`
// containers (e.g. the DAG sidebar). Position is recomputed every time the
// user hovers/focuses a `.bc-hover-parent` element. A delegated listener on
// document survives Phoenix LiveView re-renders without needing per-element
// phx-hooks.
function positionBeliefPopup(parent) {
  const popup = parent.querySelector(":scope > .bc-hover-popup");
  if (!popup) return;

  const rect = parent.getBoundingClientRect();
  const isLeft = popup.classList.contains("bc-hover-popup--left");

  popup.style.position = "fixed";

  if (isLeft) {
    // Anchor popup's right edge 6px to the left of the parent's left edge.
    popup.style.right = `${window.innerWidth - rect.left + 6}px`;
    popup.style.left = "auto";
    popup.style.top = `${Math.max(8, rect.top)}px`;
  } else {
    // Anchor popup below the parent, aligned to its left edge.
    popup.style.left = `${rect.left}px`;
    popup.style.right = "auto";
    popup.style.top = `${rect.bottom + 4}px`;
  }
}

document.addEventListener("mouseover", (event) => {
  const target = event.target;
  if (!(target instanceof Element)) return;
  const parent = target.closest(".bc-hover-parent");
  if (parent) positionBeliefPopup(parent);
});

document.addEventListener("focusin", (event) => {
  const target = event.target;
  if (!(target instanceof Element)) return;
  const parent = target.closest(".bc-hover-parent");
  if (parent) positionBeliefPopup(parent);
});

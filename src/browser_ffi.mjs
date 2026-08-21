export function onKey(handler) {
  window.addEventListener("keydown", (event) => handler(event.key));
  return undefined;
}

export function onTeardown(handler) {
  window.addEventListener("pagehide", () => handler());
  return undefined;
}

// Only this explicit extension is loaded for translation. No project extensions or tools.
// pi's CLI treats --system-prompt "" as absent; the event override preserves an empty string.
export default function (pi) {
  pi.on("before_agent_start", () => ({ systemPrompt: "" }));
}

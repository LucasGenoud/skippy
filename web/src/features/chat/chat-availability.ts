import { switchesAllow, type WorkspaceAi } from "@/lib/models/workspace";

// Whether notes chat can run over a workspace (`HomeTopBar._chatAvailable`):
// it needs the server's retrieval, and the workspace to allow chat on a
// provider from its owner. The reason decides what the screen says instead.

export type ChatAvailability =
  /** Settings have not loaded yet: say nothing either way. */
  | "unknown"
  | "ready"
  /** The server has no semantic search to retrieve notes with. */
  | "noSearch"
  /** The workspace's owner switched AI or chat off. */
  | "switchedOff"
  /** Chat is on, but the owner has no AI provider. */
  | "noProvider";

export function chatAvailability(input: { settingsLoaded: boolean; semanticSearchCapable: boolean; ai: WorkspaceAi }): ChatAvailability {
  if (!input.settingsLoaded) {
    return "unknown";
  }
  if (!input.semanticSearchCapable) {
    return "noSearch";
  }
  if (!switchesAllow(input.ai.switches, "chat")) {
    return "switchedOff";
  }
  return input.ai.providerReady ? "ready" : "noProvider";
}

/** What to tell someone, by whether they own the workspace and can fix it. */
export function unavailableMessage(availability: ChatAvailability, role: "owner" | "member"): string | null {
  switch (availability) {
    case "noSearch":
      return "Chat needs semantic search, which this server doesn't have set up.";
    case "switchedOff":
      return role === "owner" ? "AI chat is turned off in this workspace." : "The owner of this workspace has turned AI chat off.";
    case "noProvider":
      return role === "owner" ? "Connect an AI provider to chat with your notes." : "This workspace's owner hasn't connected an AI provider yet.";
    default:
      return null;
  }
}

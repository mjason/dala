function meta(name: string): string | null {
  const el = document.querySelector(`meta[name="${name}"]`);
  return el?.getAttribute("content") ?? null;
}

export const authEnabled = meta("auth-enabled") === "true";
export const mcpEnabled = meta("mcp-enabled") === "true";
export const userEmail = meta("user-email");
export const socketToken = meta("socket-token");
export const serverVersion = meta("dala-version");

import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    include: ["js/**/*.test.{ts,tsx}"],
    setupFiles: ["./vitest.setup.ts"],
    globals: false,
    coverage: {
      provider: "v8",
      include: ["js/app/**/*.{ts,tsx}"],
      exclude: ["js/app/**/*.test.{ts,tsx}"],
      // Layered gate. Tier 1: pure-logic modules — a regression here is a
      // real bug, hold them high (per-glob thresholds also REMOVE these
      // files from the global pool). Tier 2 (global): everything else is
      // DOM/xterm/WebSocket integration whose behavior the e2e suite owns —
      // the floor only catches wholesale test deletion.
      thresholds: {
        lines: 28,
        functions: 25,
        branches: 25,
        statements: 28,
        "js/app/{typeahead,streamGate,diffParse,fuzzy,patchBuilder,rpc,fileTypes,flowControl,pasteFiles,store,csv,terminalSend,pastedFileUpload}.ts":
          {
            lines: 90,
            functions: 85,
            branches: 70,
            statements: 90,
          },
        "js/app/fileDrawer/tree.ts": { lines: 90, functions: 85, branches: 70, statements: 90 },
        "js/app/keybindings.ts": { lines: 85, functions: 70, branches: 60, statements: 80 },
        "js/app/util.ts": { lines: 45, functions: 60, branches: 60, statements: 50 },
      },
    },
  },
});

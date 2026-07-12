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
    },
  },
});

import { existsSync, readdirSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { octane } from "@octanejs/vite-plugin";
import { defineConfig, type Plugin } from "vite";

const root = fileURLToPath(new URL(".", import.meta.url));
const mixEnv = process.env.MIX_ENV ?? "dev";

function cleanJavaScriptAssets(): Plugin {
  let cleaned = false;
  return {
    name: "dala-clean-javascript-assets",
    buildStart() {
      if (cleaned) return;

      const assetsDir = resolve(root, "../priv/static/assets");
      rmSync(resolve(assetsDir, "chunks"), { recursive: true, force: true });
      if (!existsSync(assetsDir)) {
        cleaned = true;
        return;
      }
      for (const entry of readdirSync(assetsDir, { withFileTypes: true })) {
        if (entry.isFile() && /\.js(?:\.map)?(?:\.gz)?$/.test(entry.name)) {
          rmSync(resolve(assetsDir, entry.name));
        }
      }
      cleaned = true;
    },
  };
}

export default defineConfig({
  base: "/assets/",
  plugins: [cleanJavaScriptAssets(), octane()],
  resolve: {
    alias: {
      "@": root,
      "phoenix-colocated": resolve(root, `../_build/${mixEnv}/phoenix-colocated`),
    },
  },
  build: {
    target: "esnext",
    outDir: resolve(root, "../priv/static/assets"),
    emptyOutDir: false,
    rollupOptions: {
      input: {
        index: resolve(root, "js/index.tsx"),
        app: resolve(root, "js/app.js"),
      },
      output: {
        entryFileNames: "[name].js",
        chunkFileNames: "chunks/[name]-[hash].js",
        assetFileNames: "[name]-[hash][extname]",
      },
    },
  },
});

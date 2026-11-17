/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Local development calls the live dev API through the dev host (same paths as production).
const API_TARGET = process.env.API_TARGET ?? "https://app-agamim-catalog-dev-dc3eee23.azurewebsites.net";

export default defineConfig({
  plugins: [react()],
  build: {
    target: "es2022",
    sourcemap: true,
    assetsDir: "assets",
  },
  server: {
    proxy: {
      "/api": { target: API_TARGET, changeOrigin: true, secure: true },
    },
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/test/setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
    coverage: {
      provider: "v8",
      include: ["src/**/*.{ts,tsx}"],
      exclude: ["src/test/**", "src/main.tsx", "src/**/*.test.{ts,tsx}"],
      thresholds: { lines: 80, functions: 80, statements: 80, branches: 70 },
    },
  },
});

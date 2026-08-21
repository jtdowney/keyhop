import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";
import gleam from "vite-gleam";

export default defineConfig({
  base: "./",
  plugins: [tailwindcss(), gleam()],
  clearScreen: false,
  server: { strictPort: true },
  build: { rollupOptions: { checks: { invalidAnnotation: false } } },
});

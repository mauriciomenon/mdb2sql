// NIVEL BASICO: Vite e o bundler que compila o codigo Svelte
// Transforma .svelte files em JavaScript que roda no browser

// NIVEL TECNICO: Vite dev server with HMR, build optimization
import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

const outDir = process.env.OUT_DIR || `dist/${process.platform}-${process.arch}`;

export default defineConfig({
  plugins: [svelte()],

  // NIVEL BASICO: clearScreen false evita limpar terminal no hot reload
  clearScreen: false,

  // NIVEL BASICO: server config para dev mode
  server: {
    port: 1420,
    strictPort: true,
  },

  // NIVEL TECNICO: Tauri expects specific env var patterns
  envPrefix: ['VITE_', 'TAURI_'],

  build: {
    // NIVEL TECNICO: Target modern browsers (Tauri uses latest webview)
    target: ['es2021', 'chrome100', 'safari13'],
    minify: !process.env.TAURI_DEBUG ? 'esbuild' : false,
    sourcemap: !!process.env.TAURI_DEBUG,
    outDir,
  },
});

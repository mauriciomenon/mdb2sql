// NIVEL BASICO: Vite e o bundler que compila o codigo Svelte
// Transforma .svelte files em JavaScript que roda no browser

// NIVEL TECNICO: Vite dev server with HMR, build optimization
import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import { VERSION as svelteVersion } from 'svelte/compiler';

const outDir = process.env.OUT_DIR || 'dist';

export default defineConfig({
  plugins: [svelte()],

  // versao exata do Svelte empacotado, mostrada no dialogo About
  define: { __SVELTE_VERSION__: JSON.stringify(svelteVersion) },

  // NIVEL BASICO: clearScreen false evita limpar terminal no hot reload
  clearScreen: false,

  // NIVEL BASICO: server config para dev mode
  server: {
    port: 1420,
    strictPort: true,
  },

  // NIVEL TECNICO: Tauri expects specific env var patterns
  envPrefix: ['VITE_', 'TAURI_ENV_*'],

  build: {
    // NIVEL TECNICO: Target latest Tauri webview without legacy transforms
    target: 'esnext',
    minify: !process.env.TAURI_ENV_DEBUG ? 'esbuild' : false,
    sourcemap: !!process.env.TAURI_ENV_DEBUG,
    outDir,
  },
});

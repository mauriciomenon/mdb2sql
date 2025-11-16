// NIVEL BASICO: Configuracao Vite para React
// Build tool que compila JSX/TSX em JavaScript otimizado

import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// NIVEL TECNICO: Vite config with React plugin and optimizations
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
    minify: 'esbuild',
    target: 'es2021',
  },
  server: {
    port: 3000,
  },
});

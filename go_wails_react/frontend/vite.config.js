import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const platformOut = process.env.OUT_DIR || `dist/${process.platform}-${process.arch}`

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react({ fastRefresh: false })],
  server: {
    port: 34115
  },
  build: {
    outDir: platformOut,
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: 'assets/[name].js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: 'assets/[name].[ext]'
      }
    }
  },
  test: {
    environment: 'jsdom',
    setupFiles: './src/setupTests.js',
    globals: true
  }
})

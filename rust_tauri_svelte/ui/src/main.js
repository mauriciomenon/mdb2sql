// NIVEL BASICO: Entry point do frontend Svelte
// Importa o componente principal e monta na div#app do HTML

// NIVEL TECNICO: Svelte compiler transforms App.svelte into vanilla JS
import App from './App.svelte';

const app = new App({
  target: document.getElementById('app'),
});

export default app;

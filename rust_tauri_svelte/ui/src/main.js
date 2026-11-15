// NIVEL BASICO: Entry point do frontend Svelte
// Importa o componente principal e monta na div#app do HTML

// NIVEL TECNICO: Svelte 5 removed `new App()`; components are mounted with mount()
import { mount } from 'svelte';
import App from './App.svelte';

const app = mount(App, {
  target: document.getElementById('app'),
});

export default app;

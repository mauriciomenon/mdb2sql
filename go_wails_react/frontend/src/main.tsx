// NIVEL BASICO: Entry point React
// Cria root React e renderiza componente App na div#root

import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import './index.css';

// NIVEL TECNICO: React 18 concurrent mode with createRoot
ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);

// Entry point React - cria root e renderiza componente App na div#root
// !T: React 18 concurrent mode with createRoot and StrictMode

import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import './index.css';

// !T: React 18 concurrent mode with createRoot
ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);

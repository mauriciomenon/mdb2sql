// NIVEL BASICO: Componente principal React
// useState gerencia estado (variaveis que re-renderizam quando mudam)

import { useState } from 'react';
import './App.css';

function App() {
  // NIVEL BASICO: Hooks React para estado
  const [name, setName] = useState('');
  const [greetMsg, setGreetMsg] = useState('');

  // NIVEL BASICO: Funcao que chama metodo Go via Wails
  // window.go.main.App.Greet sera gerado automaticamente pelo Wails
  async function greet() {
    try {
      // NIVEL TECNICO: Wails bindings (sera gerado pelo wails generate)
      // const result = await window.go.main.App.Greet(name);
      // setGreetMsg(result);

      // Placeholder ate gerar bindings
      setGreetMsg(`Hello ${name}! Welcome to MDB2SQL (Go backend)`);
    } catch (err) {
      console.error(err);
    }
  }

  return (
    <div className="container">
      <h1>MDB2SQL</h1>

      <div className="input-box">
        <input
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Enter your name"
        />
        <button onClick={greet}>Greet</button>
      </div>

      {greetMsg && <p className="result">{greetMsg}</p>}
    </div>
  );
}

export default App;

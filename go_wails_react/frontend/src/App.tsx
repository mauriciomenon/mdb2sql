import { useEffect, useMemo, useState } from 'react';
import './App.css';

declare global {
  interface Window {
    go: {
      main: {
        App: {
          LoadDatabase: (dbPath: string) => Promise<string[]>;
          GetTableData: (tableName: string, limit: number) => Promise<Record<string, any>[]>;
          GetRowCount: (tableName: string) => Promise<number>;
          GetTableSchema?: (tableName: string) => Promise<{ name: string; type: string; null: string }[]>;
        };
      };
    };
  }
}

function App() {
  const [tables, setTables] = useState<string[]>([]);
  const [selectedTable, setSelectedTable] = useState<string>('');
  const [tableData, setTableData] = useState<Record<string, any>[]>([]);
  const [rowCount, setRowCount] = useState<number>(0);
  const [status, setStatus] = useState<string>('No database loaded');
  const [error, setError] = useState<string>('');
  const [dbPath, setDbPath] = useState<string>('');
  const [schema, setSchema] = useState<{ name: string; type: string; null: string }[]>([]);

  const bridge = useMemo(() => window?.go?.main?.App, []);

  async function loadDatabase(pathOverride?: string) {
    try {
      setError('');
      setStatus('Loading...');

      if (!bridge) {
        setStatus('IPC bridge not available (dev/test mode)');
        return;
      }

      const path = pathOverride ?? dbPath ?? '';
      const tableList = await bridge.LoadDatabase(path);

      setTables(tableList);
      setStatus(`Loaded: ${path || 'sample.duckdb'} (${tableList.length} tables)`);
      if (pathOverride !== undefined) {
        setDbPath(pathOverride);
      }

      if (tableList.length > 0) {
        await loadTable(tableList[0]);
      }
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      setError(errMsg);
      setStatus('Error loading database');
    }
  }

  async function loadTable(tableName: string) {
    try {
      setError('');
      setSelectedTable(tableName);

      if (!bridge) {
        setStatus('IPC bridge not available (dev/test mode)');
        return;
      }

      const [data, count] = await Promise.all([
        bridge.GetTableData(tableName, 100),
        bridge.GetRowCount(tableName),
      ]);

      setTableData(data);
      setRowCount(count);

      if (bridge.GetTableSchema) {
        const sch = await bridge.GetTableSchema(tableName);
        setSchema(sch);
      } else {
        setSchema([]);
      }
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      setError(errMsg);
    }
  }

  useEffect(() => {
    if (bridge) {
      void loadDatabase('');
    }
  }, [bridge]);

  const columns = tableData.length > 0 ? Object.keys(tableData[0]) : [];

  return (
    <div className="page">
      <header className="hero">
        <div>
          <p className="eyebrow">DuckDB Viewer · Wails</p>
          <h1>MDB2SQL</h1>
          <p className="subtitle">
            Carregue um arquivo .duckdb ou use o sample default para navegar tabelas, esquema e linhas.
          </p>
          <div className="actions">
            <button className="primary" onClick={() => loadDatabase('')}>
              Usar sample.duckdb
            </button>
            <button className="ghost" onClick={() => loadDatabase(dbPath)}>
              Recarregar atual
            </button>
          </div>
        </div>
        <div className="status-card">
          <span className={error ? 'status error' : 'status success'}>{error || status}</span>
          <div className="input-row">
            <label>Caminho custom:</label>
            <input
              type="text"
              placeholder="Ex: /path/to/database.duckdb"
              value={dbPath}
              onChange={(e) => setDbPath(e.target.value)}
            />
            <button onClick={() => loadDatabase(dbPath)}>Carregar</button>
          </div>
        </div>
      </header>

      <main className="grid">
        <aside className="card side">
          <div className="card-header">
            <h2>Tabelas</h2>
            <span className="pill">{tables.length}</span>
          </div>
          <ul className="table-list">
            {tables.map((table) => (
              <li
                key={table}
                className={selectedTable === table ? 'active' : ''}
                onClick={() => loadTable(table)}
              >
                {table}
              </li>
            ))}
          </ul>
          {schema.length > 0 && (
            <div className="schema">
              <h3>Schema</h3>
              <ul>
                {schema.map((c) => (
                  <li key={c.name}>
                    <span>{c.name}</span>
                    <span className="muted">
                      {c.type} · {c.null}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </aside>

        <section className="card content">
          <div className="card-header">
            <div>
              <p className="eyebrow">Tabela selecionada</p>
              <h2>{selectedTable || 'Nenhuma tabela carregada'}</h2>
            </div>
            {selectedTable && (
              <span className="pill accent">
                {tableData.length} / {rowCount} rows
              </span>
            )}
          </div>

          {tableData.length > 0 ? (
            <div className="table-container">
              <table>
                <thead>
                  <tr>
                    {columns.map((col) => (
                      <th key={col}>{col}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {tableData.map((row, idx) => {
                    const rowKey = row.UNIQID || row.id || `${selectedTable}_${idx}`;
                    return (
                      <tr key={rowKey}>
                        {columns.map((col) => (
                          <td key={col}>{String(row[col] ?? '')}</td>
                        ))}
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          ) : (
            <div className="empty">Clique em "Usar sample.duckdb" para carregar dados</div>
          )}
        </section>
      </main>
    </div>
  );
}

export default App;

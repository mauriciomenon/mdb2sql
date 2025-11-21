# Go Wails React - UI Design Guidelines

## Design System Aprovado

Este documento registra o design da interface que foi aprovado em 2025-11-20.

### Paleta de Cores

```css
/* Background Principal */
background: linear-gradient(135deg, #1e3c72 0%, #2a5298 100%);

/* Container */
background: rgba(30, 30, 30, 0.95);

/* Cor de Destaque (Accent) */
primary: #61dafb;  /* React blue */
hover: #4fa8c5;    /* Darker blue on hover */

/* Texto */
primary-text: #e0e0e0;  /* Light gray */
secondary-text: #888;    /* Medium gray */
label-text: #888;
```

### Componentes Visuais

#### 1. Botoes

```css
button {
    padding: 12px 24px;
    background: #61dafb;
    color: #1e1e1e;
    border: none;
    border-radius: 6px;
    font-weight: 600;
    font-size: 14px;
    transition: all 0.2s;
}

button:hover {
    background: #4fa8c5;
    transform: translateY(-1px);
    box-shadow: 0 4px 12px rgba(97, 218, 251, 0.3);
}

button:disabled {
    background: #555;
    cursor: not-allowed;
}
```

#### 2. Cards (Tabelas)

```css
.table-card {
    padding: 15px;
    background: rgba(50, 50, 50, 0.6);
    border-radius: 6px;
    border: 2px solid transparent;
    transition: all 0.2s;
}

.table-card:hover {
    background: rgba(60, 60, 60, 0.8);
    border-color: #61dafb;
    transform: translateY(-2px);
}

.table-card.active {
    background: rgba(97, 218, 251, 0.2);
    border-color: #61dafb;
}
```

#### 3. Status Messages

```css
.status {
    padding: 15px;
    background: rgba(40, 40, 40, 0.8);
    border-radius: 6px;
    border-left: 4px solid #61dafb;
}

.status.error {
    border-left-color: #ff5555;
    background: rgba(80, 20, 20, 0.4);
}

.status.success {
    border-left-color: #50fa7b;
}
```

#### 4. Loading Spinner

```css
.spinner {
    border: 3px solid #333;
    border-top: 3px solid #61dafb;
    border-radius: 50%;
    width: 40px;
    height: 40px;
    animation: spin 1s linear infinite;
}
```

#### 5. Tabela de Dados

```css
table {
    width: 100%;
    border-collapse: collapse;
    background: rgba(30, 30, 30, 0.6);
}

th {
    background: rgba(97, 218, 251, 0.1);
    color: #61dafb;
    font-weight: 600;
    padding: 12px;
}

td {
    padding: 12px;
    border-bottom: 1px solid #333;
}

tr:hover {
    background: rgba(255, 255, 255, 0.05);
}
```

### Hierarquia de Informacao

1. **Titulo Principal**: `font-size: 2em`, `color: #61dafb`
2. **Subtitulo**: `font-size: 0.9em`, `color: #888`
3. **Headers de Secao**: `font-size: 1.2em`, `color: #61dafb`
4. **Texto Corpo**: `font-size: 1em`, `color: #e0e0e0`
5. **Labels**: `font-size: 0.85em`, `color: #888`
6. **Valores Destacados**: `font-size: 1.4em`, `color: #61dafb`, `font-weight: 600`

### Grid Layouts

#### Info Cards Grid
```css
.info-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 15px;
}
```

#### Tables Grid
```css
.tables-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 10px;
}
```

### Animacoes e Transicoes

- Hover transitions: `0.2s`
- Transform on hover: `translateY(-1px)` ou `translateY(-2px)`
- Box shadow on hover: `0 4px 12px rgba(97, 218, 251, 0.3)`
- Spinner animation: `1s linear infinite`

### Principios de Design

1. **Contraste**: Fundo escuro com destaques em azul cyan (#61dafb)
2. **Espacamento**: Padding generoso (15px-30px) para respiracao
3. **Feedback Visual**: Todos os elementos interativos tem hover states
4. **Loading States**: Sempre mostrar spinners durante operacoes assincronas
5. **Mensagens de Status**: Cores distintas para sucesso (verde), erro (vermelho), info (azul)
6. **Responsividade**: Grid auto-fit/auto-fill para adaptar a diferentes tamanhos

### Fonte

```css
font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Roboto', 'Oxygen', 'Ubuntu', 'Cantarell', sans-serif;
```

### Observacoes Importantes

- Evitar emojis e figuras
- Usar apenas alfabeto basico e simbolos de programacao
- Border-radius consistente: 6px para elementos pequenos, 12px para containers
- Box-shadow apenas em hover states para nao sobrecarregar visualmente
- Transparencias (rgba) para criar profundidade sem pesar a interface

---

**Data de Aprovacao**: 2025-11-20
**Autor**: Claude Code
**Status**: APROVADO PELO USUARIO

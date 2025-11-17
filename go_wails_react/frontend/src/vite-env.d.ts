/// <reference types="vite/client" />

// NIVEL BASICO: Declaracoes de tipos para arquivos nao-TypeScript
// NIVEL TECNICO: Allows importing CSS/images without type errors

declare module '*.css' {
  const content: Record<string, string>;
  export default content;
}

declare module '*.svg' {
  import * as React from 'react';
  export const ReactComponent: React.FunctionComponent<React.SVGProps<SVGSVGElement> & { title?: string }>;
  const src: string;
  export default src;
}

declare module '*.png' {
  const value: string;
  export default value;
}

declare module '*.jpg' {
  const value: string;
  export default value;
}

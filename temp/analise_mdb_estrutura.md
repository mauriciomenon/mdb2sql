# ANALISE ESTRUTURA MDB

---

## DATABASE FILES

Total: 11 arquivos .accdb em poc/importacao/

### Listagem Ordenada

```
2025-05-09 DB2.accdb
2025-05-27 DB3.accdb
2025-06-24 DB4.accdb
2025-07-24 DB5.accdb
2025-08-26 DB1.accdb
2025-09-16 DB2.accdb
2025-09-16 DB3.accdb
2025-11-05 DB4.accdb          <- ULTIMO (mais recente)
DB2_01_08_2019.accdb
DB2_04_12_2020.accdb
DB2_16_01_2019.accdb
```

### Observacoes

- Formato data: YYYY-MM-DD DBN
- Numeros DB nao sequenciais (DB1, DB2, DB3, DB4, DB5)
- Mesmo mes pode ter multiplos DBs (2025-09-16: DB2 e DB3)
- Alguns arquivos antigos com formato diferente (DD_MM_YYYY)

---

## ULTIMO BANCO: 2025-11-05 DB4.accdb

### Estatisticas

- **Total tabelas**: 306
- **Prefixo comum**: RANGER_SO*
- **Sistema**: Parece ser sistema SCADA/EMS (energia eletrica)

### Padroes de Nomenclatura

Tabelas seguem formato: `RANGER_SO[SIGLA]`

Exemplos por categoria (inferido):
- Accumulator: SOACCU
- General: SOGEN, SOAGC, SOAGTL
- Alarm: SOALIM, SOALTL, SOANLG
- Communication: SOCDC, SOCIRP, SOCLET
- Historical: SOHIST, SOHISG, SOHISP
- Load: SOLOA1-4, SOLOAD
- Status: SOSTAT
- Variables: SOVARS, SOVARS_BAK, SOVARS_ST

### Exemplo Estrutura: RANGER_SOACCU

```sql
CREATE TABLE [RANGER_SOACCU] (
    [RTUNO]   Numeric (10, 0),   -- RTU number (ID?)
    [PNTNO]   Numeric (10, 0),   -- Point number (ID?)
    [SUBNAM]  Text (8),          -- Substation name
    [PNTNAM]  Text (48),         -- Point name
    [IMPLM]   Text (4),
    [PSEUDO]  Text (4),
    [BIAS]    Double,
    [SCALE]   Double,
    [VALUE]   Double,            -- Current value
    [HILIM]   Double,            -- High limit
    [LOLIM]   Double,            -- Low limit
    [HISFLG]  Text (4),          -- Historical flag
    [PHISID]  Text (80),         -- Physical ID
    [UNIQID]  Numeric (10, 0),   -- Unique ID (PRIMARY KEY candidate)
    ...
    -- Total: 68 campos
)
```

### Campos Potencialmente Importantes

**IDs:**
- RTUNO, PNTNO, UNIQID, OID, DPLYID
- Provavel PK: UNIQID (unique identifier)

**Nomes/Descricoes:**
- SUBNAM, PNTNAM, PDESCR, PHISID

**Valores/Medidas:**
- VALUE, BIAS, SCALE, HILIM, LOLIM

**Flags:**
- HISFLG, ESAFLG, V2TAG, V3TAG

**Timestamps/Auditing:**
- Nao visiveis nesta tabela (precisaria verificar outras)

---

## PROXIMOS PASSOS

### Analise Detalhada

1. Identificar tabela principal (maior volume dados)
2. Mapear PKs e FKs entre tabelas
3. Identificar tabelas com timestamps
4. Identificar campos de auditoria (created_at, updated_at)

### Conversao

1. Converter ultimo banco (2025-11-05 DB4.accdb) para DuckDB
2. Executar queries de analise:
   - Count de registros por tabela
   - Identificar campos unicos
   - Detectar relacoes via FK naming patterns

### Schema Mapping

Criar arquivos config/:
- `schemas/ranger_schema.json` (tipos inferidos)
- `column_mappings/ranger_priority.json` (IDs, principais)
- `table_rules/ranger_relations.json` (FKs detectadas)

---

## QUERIES ANALISE NECESSARIAS

```sql
-- Count registros por tabela
SELECT COUNT(*) FROM RANGER_SOACCU;

-- Identificar campos unicos
SELECT COUNT(DISTINCT UNIQID) FROM RANGER_SOACCU;

-- Verificar duplicatas
SELECT UNIQID, COUNT(*) FROM RANGER_SOACCU GROUP BY UNIQID HAVING COUNT(*) > 1;

-- Amostra dados
SELECT * FROM RANGER_SOACCU LIMIT 10;
```

---

**Analise inicial completa. Pronto para conversao e Feature 1.**

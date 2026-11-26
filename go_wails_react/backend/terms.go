// Pesquisa de termos (aba Termos): uma lista colada, um termo por linha, procurada em todas as colunas das tabelas
// !T: Runs in the engine, never row by row in the UI: the terms are a relation (VALUES, in pasted order) joined to
// each table. "Whole value" compares each cell, as trimmed lowercase text, with the term (a hash join); "contains"
// looks for the term inside the lowercase text of the cells. No table is created, so the open file, its copy and the
// in-memory catalog stay as they are, and every query works on any connection of the pool and in the exporters.

package backend

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"mdb2sql/i18n"
)

// TermHit: the rows of one table found by one term
type TermHit struct {
	Term  string `json:"term"`
	Table string `json:"table"`
	Rows  int    `json:"rows"`
}

// TermsResult is the answer of a term search
type TermsResult struct {
	Terms    []string    `json:"terms"`    // the terms searched (no repeats), in pasted order
	Repeated int         `json:"repeated"` // pasted lines that repeat an earlier term
	Hits     []TermHit   `json:"hits"`     // term x table with rows, in term order and then table list order
	Tables   []TableHits `json:"tables"`   // tables with rows found, in table list order (a row found by 2 terms counts once)
	NotFound []string    `json:"notFound"` // terms that found nothing, in pasted order
}

// CleanTerms turns the pasted lines into terms: spaces at the ends removed, empty lines dropped, and a term already
// in the list (ignoring case, as the search does) kept once; repeated = how many lines were such repeats
func CleanTerms(lines []string) (terms []string, repeated int) {
	seen := map[string]bool{}
	for _, line := range lines {
		term := strings.TrimSpace(line)
		if term == "" {
			continue
		}
		if key := strings.ToLower(term); seen[key] {
			repeated++
		} else {
			seen[key] = true
			terms = append(terms, term)
		}
	}
	return terms, repeated
}

// numericTypes are the column types whose cells are numbers: "Whole value" compares their value (standard 13a)
var numericTypes = map[string]bool{
	"TINYINT": true, "SMALLINT": true, "INTEGER": true, "BIGINT": true, "HUGEINT": true, "UTINYINT": true,
	"USMALLINT": true, "UINTEGER": true, "UBIGINT": true, "UHUGEINT": true, "FLOAT": true, "REAL": true,
	"DOUBLE": true, "DECIMAL": true, "NUMERIC": true,
}

func numericType(t string) bool {
	base, _, _ := strings.Cut(strings.ToUpper(t), "(")
	return numericTypes[strings.TrimSpace(base)]
}

// numKey is the key of one reading of a number (v, a DOUBLE expression): a mark no text has, then the number as text,
// so 216, 216.0 and "216,0" give one key; NULL when v is NULL
// shortcut: through DOUBLE, integers above 2^53 may meet a neighbor; exact keys if such values ever matter
func numKey(v string) string { return "chr(30) || CAST(" + v + " AS VARCHAR)" }

// numberLike: the texts that may read as a number (digits with "." or "," between them), a cheap filter before the
// readings
const numberLike = "'[+-]?[0-9]+([.,][0-9]+)*'"

// The two readings of a number-like text, by the owner's loose rule (standard 13a; the same as the Python,
// python_pyqt6\src\backend\terms.py): dot decimal with comma thousands, comma decimal with dot thousands; a thousands
// mark only between groups of 3 digits. So with both marks only the reading where the last is the decimal one fits
// (1.234,5 = 1,234.5 = 1234.5), one mark repeated is thousands (1.234.567), one mark alone reads both ways when they
// fit (1,234 = 1.234 or 1234; 216,0 = 216, never 2160; 0,1 = 0.1, never 1; 1234,567 = 1234.567 only)
const (
	dotNumber   = `[+-]?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?`
	commaNumber = `[+-]?(?:\d+|\d{1,3}(?:\.\d{3})+)(?:,\d+)?`
)

// readings is the SQL list of the keys of the readings of the number-like text x (a column); a reading that does not
// fit is NULL, which meets nothing
func readings(x string) string {
	return "[CASE WHEN regexp_full_match(" + x + ", '" + dotNumber + "') THEN " + numKey("TRY_CAST(replace("+x+", ',', '') AS DOUBLE)") +
		" END, CASE WHEN regexp_full_match(" + x + ", '" + commaNumber + "') THEN " +
		numKey("TRY_CAST(replace(replace("+x+", '.', ''), ',', '.') AS DOUBLE)") + " END]"
}

// numberTerm tells whether a term reads as a number (then the numeric keys are worth computing)
var numberTerm = regexp.MustCompile(`^[+-]?[0-9]+([.,][0-9]+)*$`)

// termsWith is the WITH of a term search in one table, ending in hits(rn, ord, term): each row (rn = its rowid, or its
// position for a table without one, as base.mdb2sql_rn) and each term (ord = position in the pasted list) that finds
// it, once. Whole value: the trimmed lowercase text of every cell equal to the term; and, when a term reads as a
// number, the value of the numeric cells and the readings of the number-like texts equal to a reading of the term.
// Contains: the cells of a row as one lowercase text, apart by a control character no term has, containing the term.
func termsWith(table string, schema []ColumnSchema, rowID bool, terms []string, contains bool) string {
	// base is read more than once: a position (no rowid) is numbered once, so every read sees the same numbers
	base, rn := "MATERIALIZED (", "row_number() OVER ()"
	if rowID {
		base, rn = "(", "rowid"
	}
	numeric := false
	values := make([]string, len(terms))
	for i, term := range terms {
		values[i] = fmt.Sprintf("(%d, %s)", i, quoteLiteral(term))
		numeric = numeric || numberTerm.MatchString(term)
	}
	var texts, numbers []string
	for _, c := range schema {
		if !contains && numericType(c.Type) {
			numbers = append(numbers, numKey("CAST("+quoteIdent(c.Name)+" AS DOUBLE)"))
		} else {
			texts = append(texts, "CAST("+quoteIdent(c.Name)+" AS VARCHAR)")
		}
	}
	with := "WITH base AS " + base + "SELECT " + rn + " AS mdb2sql_rn, * FROM " + quoteIdent(table) + "), v(ord, term) AS (VALUES " +
		strings.Join(values, ", ") + "), "
	if contains {
		return with + "keys AS (SELECT mdb2sql_rn AS rn, lower(concat_ws(chr(31), " + strings.Join(texts, ", ") + ")) AS key FROM base), " +
			"hits AS (SELECT DISTINCT k.rn, t.ord, t.term FROM keys k JOIN v t ON contains(k.key, lower(t.term)))"
	}
	for i := range texts {
		texts[i] = "trim(" + texts[i] + ")"
	}
	keys := []string{}
	if len(texts) > 0 {
		with += "cells AS (SELECT mdb2sql_rn AS rn, unnest(list_distinct([" + strings.Join(texts, ", ") + "])) AS x FROM base), "
		keys = append(keys, "SELECT rn, lower(x) AS key FROM cells")
	}
	termKeys := "SELECT ord, term, lower(term) AS key FROM v"
	if numeric {
		if len(numbers) > 0 {
			keys = append(keys, "SELECT mdb2sql_rn AS rn, unnest(["+strings.Join(numbers, ", ")+"]) AS key FROM base")
		}
		if len(texts) > 0 {
			keys = append(keys, "SELECT rn, unnest("+readings("x")+") AS key FROM cells WHERE regexp_full_match(x, "+numberLike+")")
		}
		termKeys += " UNION ALL SELECT ord, term, unnest(" + readings("term") + ") FROM v WHERE regexp_full_match(term, " + numberLike + ")"
	}
	if len(keys) == 0 { // no column the terms can meet
		keys = append(keys, "SELECT NULL::BIGINT AS rn, NULL::VARCHAR AS key WHERE false")
	}
	return with + "keys AS (" + strings.Join(keys, " UNION ALL ") + "), t AS (" + termKeys + "), " +
		"hits AS (SELECT DISTINCT k.rn, t.ord, t.term FROM keys k JOIN t ON k.key = t.key)"
}

// termsSelect is the SELECT of the rows the terms find in table: the columns of the table as they are (names, order
// and types; no Term column, standard 19d), each row once, in the order of the first term that finds it and then of
// the table
func (m *DBManager) termsSelect(table string, terms []string, contains bool) (string, error) {
	rowID, err := m.hasRowID(table) // also validates the table name
	if err != nil {
		return "", err
	}
	if len(terms) == 0 {
		return "", fmt.Errorf("no term to search")
	}
	schema, err := m.tableSchema(table)
	if err != nil {
		return "", err
	}
	cols := make([]string, len(schema))
	for i, c := range schema {
		cols[i] = "c." + quoteIdent(c.Name)
	}
	return termsWith(table, schema, rowID, terms, contains) + " SELECT " + strings.Join(cols, ", ") +
		" FROM (SELECT rn, min(ord) AS ord FROM hits GROUP BY rn) h JOIN base c ON c.mdb2sql_rn = h.rn ORDER BY h.ord, h.rn", nil
}

// SearchTerms looks for the terms of lines (see CleanTerms) in every column of table, or with table "" of every
// table: per term and table, how many rows have it. progress gets each table as its search starts; ctx stops it.
func (m *DBManager) SearchTerms(ctx context.Context, lines []string, contains bool, table string, progress Progress) (TermsResult, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.conn == nil {
		return TermsResult{}, fmt.Errorf("no database connected")
	}
	terms, repeated := CleanTerms(lines)
	res := TermsResult{Terms: terms, Repeated: repeated, Hits: []TermHit{}, Tables: []TableHits{}, NotFound: []string{}}
	if len(terms) == 0 {
		res.Terms = []string{}
		return res, nil
	}
	tables := m.tableList
	if table != "" {
		tables = []string{table}
	}
	counts := make([]map[int]int, len(tables)) // per table: position of the term -> rows
	for i, tb := range tables {
		if err := ctx.Err(); err != nil {
			return TermsResult{}, err
		}
		progress(i+1, len(tables), tb)
		schema, err := m.tableSchema(tb)
		if err != nil {
			return TermsResult{}, err
		}
		rowID, err := m.hasRowID(tb)
		if err != nil {
			return TermsResult{}, err
		}
		// per term, its rows; per table, its rows found by any term, each once (the grid and the report show each row once)
		rows, err := m.conn.QueryContext(ctx, termsWith(tb, schema, rowID, terms, contains)+
			" SELECT ord, count(*), (SELECT count(DISTINCT rn) FROM hits) FROM hits GROUP BY ord")
		if err != nil {
			return TermsResult{}, fmt.Errorf("%s: %w", tb, err)
		}
		counts[i] = map[int]int{}
		total := 0
		for rows.Next() {
			var ord, n int
			if err := rows.Scan(&ord, &n, &total); err != nil {
				rows.Close()
				return TermsResult{}, err
			}
			counts[i][ord] = n
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return TermsResult{}, fmt.Errorf("%s: %w", tb, err)
		}
		if total > 0 {
			res.Tables = append(res.Tables, TableHits{tb, total})
		}
	}
	for ord, term := range terms {
		found := false
		for i, tb := range tables {
			if n := counts[i][ord]; n > 0 {
				res.Hits = append(res.Hits, TermHit{term, tb, n})
				found = true
			}
		}
		if !found {
			res.NotFound = append(res.NotFound, term)
		}
	}
	return res, nil
}

// TermRows returns the rows the terms find in table (see termsSelect), at most limit (0 = all)
func (m *DBManager) TermRows(ctx context.Context, table string, terms []string, contains bool, limit int) (QueryResult, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.conn == nil {
		return QueryResult{}, fmt.Errorf("no database connected")
	}
	query, err := m.termsSelect(table, terms, contains)
	if err != nil {
		return QueryResult{}, err
	}
	return queryResult(ctx, m.conn, query, limit)
}

// TermsSheets names the sheets of the Advanced Search report (also its tables and CSV files): one per table with rows
// found, named as the table (standard 19d: no result sheet)
func TermsSheets(res TermsResult) []string {
	names := []string{}
	for _, t := range res.Tables {
		names = append(names, t.Table)
	}
	return names
}

// ExportTerms writes the report of a term search (res, as SearchTerms returned it): one sheet per table with rows
// found, the rows as termsSelect gives them (the columns of the table, each row once; standard 19d). SQLite and
// DuckDB: the same, as tables with those names. CSV: out is a folder, one file per sheet.
func (m *DBManager) ExportTerms(ctx context.Context, res TermsResult, contains bool, format, out string, progress Progress) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	if len(res.Tables) == 0 {
		return errors.New(i18n.T("terms.nothingToExport"))
	}
	sheets := TermsSheets(res)
	if format == "sqlite" || format == "duckdb" {
		sheets = uniqueFold(sheets) // two table names may differ only in case
	}
	var items []exportItem
	for i, t := range res.Tables {
		query, err := m.termsSelect(t.Table, res.Terms, contains)
		if err != nil {
			return err
		}
		items = append(items, exportItem{name: sheets[i], query: query})
	}
	switch format {
	case "csv":
		return m.writeCSVFolder(ctx, out, items, progress)
	case "xlsx":
		return m.writeAtomically(out, func(tmp string) error { return m.writeXLSX(ctx, tmp, items, progress, 0) })
	case "sqlite", "duckdb":
		return m.writeAtomically(out, func(tmp string) error { return copyDatabase(ctx, m.conn, format, tmp, items, progress) })
	}
	return fmt.Errorf("unknown export format %q", format)
}

// Pesquisa de termos (aba Termos): uma lista colada, um termo por linha, procurada em todas as colunas das tabelas
// !T: Runs in the engine, never row by row in the UI: the terms are a relation (VALUES, in pasted order) joined to
// each table. "Whole value" compares each cell, as trimmed lowercase text, with the term (a hash join); "contains"
// looks for the term inside the lowercase text of the cells. No table is created, so the open file, its copy and the
// in-memory catalog stay as they are, and every query works on any connection of the pool and in the exporters.

package backend

import (
	"context"
	"fmt"
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
	Tables   []TableHits `json:"tables"`   // tables with rows found, in table list order (a row found by 2 terms counts twice)
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

// termsFrom is the FROM of a term search in one table: c = the rows of the table (c.rid = the rowid, when the table has
// one) joined to t = the terms that find each row (t.ord = position in the pasted list, t.term).
// Whole value: the cells of a row as trimmed lowercase text, one line per different text (so a row with the term in two
// cells is found once), joined to the terms by equality. Contains: the cells of a row as one lowercase text, apart by a
// control character no term has, and the terms that text contains.
func termsFrom(table string, schema []ColumnSchema, rowID bool, terms []string, contains bool) string {
	cells := make([]string, len(schema))
	for i, c := range schema {
		cells[i] = "CAST(" + quoteIdent(c.Name) + " AS VARCHAR)"
		if !contains {
			cells[i] = "lower(trim(" + cells[i] + "))"
		}
	}
	key, on := "unnest(list_distinct(["+strings.Join(cells, ", ")+"]))", "c.mdb2sql_key = t.key"
	if contains {
		key, on = "lower(concat_ws(chr(31), "+strings.Join(cells, ", ")+"))", "contains(c.mdb2sql_key, t.key)"
	}
	rid := ""
	if rowID {
		rid = "rowid AS mdb2sql_rid, "
	}
	values := make([]string, len(terms))
	for i, term := range terms {
		values[i] = fmt.Sprintf("(%d, %s)", i, quoteLiteral(term))
	}
	return fmt.Sprintf("FROM (SELECT %s*, %s AS mdb2sql_key FROM %s) c JOIN (SELECT ord, term, lower(term) AS key FROM (VALUES %s) v(ord, term)) t ON %s",
		rid, key, quoteIdent(table), strings.Join(values, ", "), on)
}

// termsSelect is the SELECT of the rows the terms find in table: the term first (column named by the catalog), then
// every column of the table; in the order of the terms and, inside a term, of the table
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
	label := i18n.T("terms.col")
	cols := []string{"t.term AS " + quoteIdent(label)}
	for _, c := range schema {
		col := "c." + quoteIdent(c.Name)
		if strings.EqualFold(c.Name, label) { // a column with the name of the term column keeps its values under another
			col += " AS " + quoteIdent(c.Name+" (2)")
		}
		cols = append(cols, col)
	}
	order := " ORDER BY t.ord"
	if rowID {
		order += ", c.mdb2sql_rid"
	}
	return "SELECT " + strings.Join(cols, ", ") + " " + termsFrom(table, schema, rowID, terms, contains) + order, nil
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
		rows, err := m.conn.QueryContext(ctx, "SELECT t.ord, count(*) "+termsFrom(tb, schema, false, terms, contains)+" GROUP BY t.ord")
		if err != nil {
			return TermsResult{}, fmt.Errorf("%s: %w", tb, err)
		}
		counts[i] = map[int]int{}
		total := 0
		for rows.Next() {
			var ord, n int
			if err := rows.Scan(&ord, &n); err != nil {
				rows.Close()
				return TermsResult{}, err
			}
			counts[i][ord] = n
			total += n
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

// TermsSheets names the sheets of the Advanced Search report (also its tables and CSV files), in order: the result
// (owner 26/11, 13i: one sheet with every term), then one per table with rows found, named as the table
func TermsSheets(res TermsResult) []string {
	names := []string{i18n.T("terms.sheetResult")}
	for _, t := range res.Tables {
		names = append(names, t.Table)
	}
	return names
}

// ExportTerms writes the report of a term search (res, as SearchTerms returned it). Excel: the result sheet (Term,
// Status, Table, Rows: one line per term and table; a term not found has no table and 0 rows), then one sheet per
// table with the rows found (the term, then the columns of the table). SQLite and DuckDB: the same, as tables with
// those names. CSV: out is a folder, one file per sheet.
func (m *DBManager) ExportTerms(ctx context.Context, res TermsResult, contains bool, format, out string, progress Progress) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	term := i18n.T("terms.col")
	hits := map[string][]TermHit{}
	for _, h := range res.Hits {
		hits[h.Term] = append(hits[h.Term], h)
	}
	var summary [][]any
	for _, t := range res.Terms {
		for _, h := range hits[t] {
			summary = append(summary, []any{t, i18n.T("terms.statusFound"), h.Table, h.Rows})
		}
		if len(hits[t]) == 0 {
			summary = append(summary, []any{t, i18n.T("terms.statusNotFound"), "", 0})
		}
	}
	sheets := TermsSheets(res)
	if format == "sqlite" || format == "duckdb" {
		sheets = uniqueFold(sheets) // a table of the database may be called as the result
	}
	header := []string{term, i18n.T("terms.colStatus"), i18n.T("terms.colTable"), i18n.T("terms.colRows")}
	items := []exportItem{{name: sheets[0], query: valuesQuery(header, summary)}}
	for i, t := range res.Tables {
		query, err := m.termsSelect(t.Table, res.Terms, contains)
		if err != nil {
			return err
		}
		items = append(items, exportItem{name: sheets[i+1], query: query})
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

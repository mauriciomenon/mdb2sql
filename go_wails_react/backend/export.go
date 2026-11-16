// Exportacao: banco inteiro para .duckdb/.sqlite/.xlsx; tabela ou resultado de SQL para .csv/.xlsx
// !T: Writes to "<name>.partial.<ext>" and renames at the end, so a cancelled or failed export leaves no half file

package backend

import (
	"bufio"
	"context"
	"encoding/csv"
	"errors"
	"fmt"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf16"

	"github.com/duckdb/duckdb-go/v2"
	"github.com/xuri/excelize/v2"
)

// MaxExcelDataRows: an Excel sheet has 1,048,576 rows and the first is the header (a var so tests can split small tables)
var MaxExcelDataRows = 1048575

const maxSheetName = 31 // Excel limit, in UTF-16 units

var sheetBad = strings.NewReplacer(":", "_", `\`, "_", "/", "_", "?", "_", "*", "_", "[", "_", "]", "_")

// SheetName returns the Excel name for part (1-based) of a table: invalid characters replaced, cut to 31,
// " (2)", " (3)"... for continuation sheets and "~2", "~3"... when the cut name is already used (case-insensitive)
func SheetName(table string, part int, used map[string]bool) string {
	base := strings.Trim(sheetBad.Replace(table), "'")
	if strings.TrimSpace(base) == "" {
		base = "Sheet"
	}
	if strings.EqualFold(base, "History") { // reserved by Excel
		base += "_"
	}
	suffix := ""
	if part > 1 {
		suffix = fmt.Sprintf(" (%d)", part)
	}
	for n := 1; ; n++ {
		tag := suffix
		if n > 1 {
			tag = fmt.Sprintf("~%d", n) + suffix
		}
		// a cut may leave an apostrophe at the end, which Excel rejects
		head := strings.TrimRight(truncUTF16(base, maxSheetName-utf16Len(tag)), "'")
		name := head + tag
		if key := strings.ToLower(name); !used[key] {
			used[key] = true
			return name
		}
	}
}

func utf16Len(s string) int { return len(utf16.Encode([]rune(s))) }

func truncUTF16(s string, max int) string {
	n := 0
	for i, r := range s {
		if n += utf16.RuneLen(r); n > max {
			return s[:i]
		}
	}
	return s
}

type exportItem struct{ name, query string }

func (m *DBManager) items() []exportItem {
	items := make([]exportItem, len(m.tableList))
	for i, t := range m.tableList {
		items[i] = exportItem{t, "SELECT * FROM " + quoteIdent(t)}
	}
	return items
}

// ExportDatabase writes every table to out; format is "duckdb", "sqlite" or "xlsx"
func (m *DBManager) ExportDatabase(ctx context.Context, format, out string, progress Progress) error {
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	items := m.items()
	return m.writeAtomically(out, func(tmp string) error {
		switch format {
		case "duckdb", "sqlite":
			return m.copyDatabase(ctx, format, tmp, items, progress)
		case "xlsx":
			return m.writeXLSX(ctx, tmp, items, progress, 0)
		}
		return fmt.Errorf("unknown export format %q", format)
	})
}

// ExportTable writes one table to out (format "csv" or "xlsx")
func (m *DBManager) ExportTable(ctx context.Context, table, format, out string, progress Progress) error {
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	if _, err := m.validateTableName(table); err != nil {
		return err
	}
	total, err := m.GetRowCount(table)
	if err != nil {
		return err
	}
	return m.exportOne(ctx, exportItem{table, "SELECT * FROM " + quoteIdent(table)}, format, out, progress, total)
}

// ExportQuery writes the full result of a SQL query to out (format "csv" or "xlsx"); the sheet is "Result"
func (m *DBManager) ExportQuery(ctx context.Context, query, format, out string, progress Progress) error {
	if m.conn == nil {
		return fmt.Errorf("no database connected")
	}
	return m.exportOne(ctx, exportItem{"Result", query}, format, out, progress, 0)
}

func (m *DBManager) exportOne(ctx context.Context, it exportItem, format, out string, progress Progress, total int) error {
	return m.writeAtomically(out, func(tmp string) error {
		switch format {
		case "csv":
			return m.writeCSV(ctx, tmp, it, progress, total)
		case "xlsx":
			return m.writeXLSX(ctx, tmp, []exportItem{it}, progress, total)
		}
		return fmt.Errorf("unknown export format %q", format)
	})
}

func (m *DBManager) writeAtomically(out string, write func(tmp string) error) error {
	if same, _ := filepath.Abs(out); m.currentDB != "" && strings.EqualFold(same, m.currentDB) {
		return fmt.Errorf("cannot export over the open database file")
	}
	ext := filepath.Ext(out)
	tmp := strings.TrimSuffix(out, ext) + ".partial" + ext
	removeFiles(tmp)
	if err := write(tmp); err != nil {
		removeFiles(tmp)
		if errors.Is(err, context.Canceled) {
			return fmt.Errorf("export cancelled")
		}
		return err
	}
	if err := os.Remove(out); err != nil && !os.IsNotExist(err) {
		removeFiles(tmp)
		return err
	}
	return os.Rename(tmp, out)
}

func removeFiles(path string) {
	for _, p := range []string{path, path + ".wal", path + "-journal"} {
		_ = os.Remove(p)
	}
}

// copyDatabase attaches the target file and copies each table with CREATE TABLE AS (DuckDB maps the types)
func (m *DBManager) copyDatabase(ctx context.Context, format, path string, items []exportItem, progress Progress) error {
	conn, err := m.conn.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	attach := "ATTACH " + quoteLiteral(path) + " AS mdb2sql_out"
	if format == "sqlite" {
		ext, err := sqliteExtension()
		if err != nil {
			return err
		}
		if _, err := conn.ExecContext(ctx, "LOAD "+quoteLiteral(ext)); err != nil {
			return err
		}
		attach += " (TYPE sqlite)"
	}
	if _, err := conn.ExecContext(ctx, attach); err != nil {
		return err
	}
	// on error the file must still be closed before it is deleted
	defer conn.ExecContext(context.Background(), "DETACH DATABASE IF EXISTS mdb2sql_out")
	for i, it := range items {
		progress(i, len(items), it.name)
		q := fmt.Sprintf("CREATE TABLE mdb2sql_out.%s AS %s", quoteIdent(it.name), it.query)
		if _, err := conn.ExecContext(ctx, q); err != nil {
			return fmt.Errorf("%s: %w", it.name, err)
		}
	}
	progress(len(items), len(items), "")
	_, err = conn.ExecContext(ctx, "DETACH DATABASE mdb2sql_out")
	return err
}

// rowProgress reports rows when one table is exported (total 0 = unknown) and checks for cancel
func rowProgress(ctx context.Context, progress Progress, label string, total int) func(n int) error {
	return func(n int) error {
		if n%5000 != 0 {
			return nil
		}
		progress(n, total, label)
		return ctx.Err()
	}
}

func (m *DBManager) writeCSV(ctx context.Context, path string, it exportItem, progress Progress, total int) error {
	rows, err := m.conn.QueryContext(ctx, it.query)
	if err != nil {
		return err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return err
	}
	uuids := uuidColumns(rows)
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	bw := bufio.NewWriter(f)
	bw.WriteString("\xEF\xBB\xBF") // BOM: Excel then reads the file as UTF-8
	w := csv.NewWriter(bw)
	w.UseCRLF = true
	if err := w.Write(cols); err != nil {
		return err
	}
	values, ptrs := scanTargets(len(cols))
	record := make([]string, len(cols))
	onRow := rowProgress(ctx, progress, it.name, total)
	for n := 1; rows.Next(); n++ {
		if err := rows.Scan(ptrs...); err != nil {
			return err
		}
		fixUUIDs(values, uuids)
		for i, v := range values {
			record[i] = cellString(v)
		}
		if err := w.Write(record); err != nil {
			return err
		}
		if err := onRow(n); err != nil {
			return err
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	w.Flush()
	if err := w.Error(); err != nil {
		return err
	}
	if err := bw.Flush(); err != nil {
		return err
	}
	return f.Close()
}

func scanTargets(n int) ([]any, []any) {
	values := make([]any, n)
	ptrs := make([]any, n)
	for i := range values {
		ptrs[i] = &values[i]
	}
	return values, ptrs
}

// writeXLSX writes one sheet per item (more when an item has more rows than an Excel sheet holds)
func (m *DBManager) writeXLSX(ctx context.Context, path string, items []exportItem, progress Progress, total int) error {
	f := excelize.NewFile()
	defer f.Close()
	used := map[string]bool{}
	first := true
	for i, it := range items {
		onRow := func(int) error { return ctx.Err() }
		if len(items) == 1 {
			onRow = rowProgress(ctx, progress, it.name, total)
		} else {
			progress(i, len(items), it.name)
		}
		if err := m.writeSheets(ctx, f, used, &first, it, onRow); err != nil {
			return fmt.Errorf("%s: %w", it.name, err)
		}
	}
	if len(items) > 1 {
		progress(len(items), len(items), "")
	}
	return f.SaveAs(path)
}

func (m *DBManager) writeSheets(ctx context.Context, f *excelize.File, used map[string]bool, first *bool, it exportItem, onRow func(int) error) error {
	rows, err := m.conn.QueryContext(ctx, it.query)
	if err != nil {
		return err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return err
	}
	uuids := uuidColumns(rows)
	total := -1 // row count for the sheet dimension; unknown (-1) if the query cannot be counted
	countQuery := "SELECT count(*) FROM (" + strings.TrimRight(strings.TrimSpace(it.query), "; \t\r\n") + ")"
	if err := m.conn.QueryRowContext(ctx, countQuery).Scan(&total); err != nil {
		total = -1
	}
	header := make([]any, len(cols))
	for i, c := range cols {
		header[i] = c
	}
	var sw *excelize.StreamWriter
	part, line := 0, 0 // line = last written sheet row
	newSheet := func() error {
		if sw != nil {
			if err := sw.Flush(); err != nil {
				return err
			}
		}
		part++
		name := SheetName(it.name, part, used)
		if *first {
			if err := f.SetSheetName("Sheet1", name); err != nil {
				return err
			}
			*first = false
		} else if _, err := f.NewSheet(name); err != nil {
			return err
		}
		// the stream writer leaves <dimension ref="A1">; openpyxl read-only (and so pandas) would then see one cell
		if total >= 0 {
			last, _ := excelize.CoordinatesToCellName(max(len(cols), 1), min(total-(part-1)*MaxExcelDataRows, MaxExcelDataRows)+1)
			if err := f.SetSheetDimension(name, "A1:"+last); err != nil {
				return err
			}
		}
		if sw, err = f.NewStreamWriter(name); err != nil {
			return err
		}
		line = 1
		return sw.SetRow("A1", header)
	}
	if err := newSheet(); err != nil {
		return err
	}
	values, ptrs := scanTargets(len(cols))
	cells := make([]any, len(cols))
	for n := 1; rows.Next(); n++ {
		if line > MaxExcelDataRows {
			if err := newSheet(); err != nil {
				return err
			}
		}
		if err := rows.Scan(ptrs...); err != nil {
			return err
		}
		fixUUIDs(values, uuids)
		for i, v := range values {
			cells[i] = xlsxValue(v)
		}
		line++
		cell, _ := excelize.CoordinatesToCellName(1, line)
		if err := sw.SetRow(cell, cells); err != nil {
			return err
		}
		if err := onRow(n); err != nil {
			return err
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	return sw.Flush()
}

// xlsxValue keeps numbers, booleans and dates as Excel values; the rest becomes text
func xlsxValue(v any) any {
	switch x := v.(type) {
	case duckdb.Decimal:
		return x.Float64()
	case *big.Int:
		return x.String()
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return fmt.Sprint(x)
		}
	case float32:
		if math.IsNaN(float64(x)) || math.IsInf(float64(x), 0) {
			return fmt.Sprint(x)
		}
	case []byte:
		return cellString(x)
	case time.Time:
		if x.Year() < 1900 { // before Excel's first date
			return cellString(x)
		}
	case nil, bool, string, int8, int16, int32, int64, uint8, uint16, uint32, uint64, int, uint:
	default:
		return cellString(v)
	}
	return v
}

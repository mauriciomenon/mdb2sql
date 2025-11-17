# CONFIG DIRECTORY

Shared configuration files for all implementations.

---

## STRUCTURE

```
config/
├── schemas/               # Database schemas, types, constraints
├── column_mappings/       # Field priority, ID columns, principal fields
├── table_rules/          # Foreign keys, relations, cascade rules
└── display_preferences/  # Default views, visible columns, ordering
```

---

## USAGE

Each implementation reads from this shared config:
- **rust_tauri_svelte**: Deserialize JSON via serde
- **go_wails_react**: Unmarshal JSON via encoding/json
- **py_qt6**: Load JSON via json module

---

## FILE FORMATS

All files use JSON for cross-language compatibility.

### schemas/

Define table schemas with types and constraints.

Example: `schemas/standard_schema.json`
```json
{
  "tables": {
    "table1": {
      "columns": {
        "id": {"type": "INTEGER", "primary_key": true},
        "name": {"type": "TEXT", "nullable": false},
        "created_at": {"type": "TIMESTAMP"}
      }
    }
  }
}
```

### column_mappings/

Map which columns are IDs, principals, or metadata.

Example: `column_mappings/field_priority_map.json`
```json
{
  "table1": {
    "id_fields": ["id"],
    "principal_fields": ["name", "code"],
    "metadata_fields": ["created_at", "updated_at"]
  }
}
```

### table_rules/

Define relationships and constraints.

Example: `table_rules/relations_map.json`
```json
{
  "foreign_keys": {
    "table2": {
      "parent_id": {
        "references": "table1.id",
        "on_delete": "CASCADE"
      }
    }
  }
}
```

### display_preferences/

Default UI configurations.

Example: `display_preferences/default_views.json`
```json
{
  "table1": {
    "visible_columns": ["id", "name", "code"],
    "column_order": ["id", "name", "code", "created_at"],
    "sort_by": "id",
    "sort_order": "ASC"
  }
}
```

---

## NOTES

- Files are optional (graceful defaults if missing)
- Can be overridden per-implementation if needed
- JSON chosen for universality (all languages support it)

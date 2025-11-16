# ROADMAP v0.3.0 - MDB to DuckDB Converter

Current version: v0.2.0
Target version: v0.3.0
Created: 2025-01-06
Estimated duration: 12 weeks
Status: Planning

---

## Index
- Overview
- Objectives
- Target Architecture
- Phases
- Risks
- Deliverables
- Acceptance Criteria
- Next Steps

---

## Overview
- Current state: functional scripts to convert MDB/ACCDB to DuckDB, no automated tests or CI/CD.
- v0.3.0 goal: modular architecture, automated tests, CI/CD, additional output options, and professional documentation.

---

## Objectives
- Quality: correct conversions, data integrity validation, prevent regressions with tests.
- Professionalization: unified CLI, code standards, clear documentation, automated build/test.
- Scalability: support DuckDB, SQLite, and PostgreSQL; enable new implementations easily.
- Usability: simple installation, clear messages, practical examples.

---

## Target Architecture (high level)
- Package `mdb2sql` with modules: cli, config, utils, validators.
- `converters/`: base.py, mdbtools.py, jackcess.py, pyaccess.py, pyodbc.py.
- `outputs/`: base.py, duckdb.py, sqlite.py, postgres.py.
- Tests: unit, integration, performance, fixtures.
- Automation: GitHub Actions for tests, lint, and release; optional Docker images.

---

## Phases
1) Refactor and modularize (weeks 1-2)
- Create base classes for converters and outputs.
- Migrate existing scripts into the modular structure.
- Implement unified CLI with commands: convert, list-converters, validate.

2) Automated testing (weeks 3-4)
- Configure pytest and coverage.
- Add unit and integration tests.
- Automate basic benchmarks.

3) CI/CD (week 5)
- Workflows for tests and lint.
- Publish coverage reports.

4) Additional outputs (weeks 6-7)
- Implement SQLite and PostgreSQL outputs.
- Post-import data validation.

5) Docker and distribution (weeks 8-9)
- Docker images and optional multi-arch.
- Usage docs with Docker.

6) Quality and docs (weeks 10-11)
- Enforce formatting and lint.
- Technical and user documentation.

7) Release (week 12)
- Final tests, changelog, and tag v0.3.0.

---

## Risks
- External dependencies (mdbtools, Java, ODBC) vary across platforms. Mitigation: document requirements and provide alternatives.
- Time may be insufficient for full scope. Mitigation: prioritize tests, CI/CD, and CLI; defer non-critical items.
- Performance with external databases. Mitigation: batch inserts and native load commands (e.g., COPY).

---

## Deliverables
- Modular code with 4 converters and 3 outputs (DuckDB, SQLite, PostgreSQL).
- Unified CLI with core commands.
- Test suite with 80 percent coverage target.
- Active CI/CD workflows.
- Updated documentation (README, installation and usage guides).

---

## Acceptance Criteria
- Conversion works via CLI for all converters.
- Outputs for DuckDB, SQLite, and PostgreSQL validated by tests.
- Test coverage >= 80 percent.
- CI workflows pass on Linux, macOS, and Windows.
- Documentation is clear with no critical gaps.

---

## Next Steps
```bash
# Create working branch
git checkout -b develop

# Initial folder structure
mkdir -p mdb2sql/{converters,outputs}
mkdir -p tests/{unit/{converters,outputs},integration,performance,fixtures}
mkdir -p .github/workflows docs docker scripts

# Dev dependencies (example)
pip install pytest pytest-cov flake8 mypy
```

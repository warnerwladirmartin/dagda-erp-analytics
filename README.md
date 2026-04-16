# ERP Analytics — Data Investigation & Semantic Layer

> SQL-based analytics engineering project for a manufacturing & distribution company running a legacy ERP (Datasul/Progress on PostgreSQL). Built a semantic layer of SQL views, investigated inventory discrepancies, mapped approval lead times, and designed a dimensional model for Power BI consumption.

## Context

A lubricant manufacturing company operates across **22 business units** (1 factory, 1 packaging plant, 18 commercial branches, 1 distributor, 1 subsidiary) on a legacy ERP with a PostgreSQL read-only database. The existing BI relied on manual Excel exports — no live connection to the ERP.

**Challenges:**
- Double-counting of revenue (inter-company transfers counted as sales)
- Ghost inventory in production buffers (~130K liters phantom stock)
- No visibility into order approval lead times
- No live stock or production data in the BI
- 22 companies consolidated without proper classification

## What I Built

### 1. Semantic Layer (SQL Views)

Designed **7 SQL queries** that transform raw ERP tables into clean, business-ready datasets:

| View | Purpose | Key Logic |
|---|---|---|
| `vw_dim_empresa` | Company dimension with classification | Joins master + custom classification (factory/branch/distributor) |
| `vw_fechamento_vendas` | Sales fact table | Triple-check anti-duplication filter (CFOP whitelist + cancel filter + inter-company exclusion) |
| `vw_fechamento_pedidos` | Orders with backlog | Calculates open-to-invoice qty, includes margin data from CRM; real entry dates sourced from `crm_audit` (overwrite-safe) |
| `vw_fechamento_estoque` | Live inventory by lot | Enriched with real production date (derived from first production posting) |
| `vw_fechamento_apontamentos` | Production postings | Replaces legacy character-mode report (PRD0157) |
| `vw_fechamento_clientes` | Customer dimension | Dynamic status (Active/At Risk/Inactive based on days since last purchase) + ABC classification |
| `vw_dim_item` | Product dimension | Joins `item`, `linha_prod`, `familia`, and `peso_especifico`; `familia` table needed for Lubricants vs. Coolants split |

**Anti-duplication filter** (critical business rule):
```sql
WHERE natureza_operacao IN (1, 11, 13)     -- CFOP whitelist: Sale, Scrap Sale, Export
  AND sit_nota_fiscal = 'N'                 -- Exclude cancelled
  AND cliente NOT IN (                      -- Exclude inter-company
      SELECT cod_cliente FROM empresa WHERE cod_cliente IS NOT NULL
  )
```

### 2. Inventory Ghost Investigation

Discovered and diagnosed **~130K liters of phantom inventory** across 3 warehouse addresses:

```
Production posts PA to address PRD (APON operation)
    ↓
Logistics picks up physically but doesn't transfer in the system (2-3% leak)
    ↓
PRD accumulates phantom stock (78 lots, some 60+ days old)
    ↓
Returns from customers auto-feed AVA/CON addresses
    ↓
Logistics "borrows" from AVA/CON to cover PRD gap
    ↓
AVA shows negative net balance (more exits than entries — mathematically impossible)
```

**Evidence:** Monthly balance of AVA (damaged goods) showed **negative net flow every single month** — proving it was being used as a pass-through account to offset the PRD leak.

| Month | AVA Entries | AVA Exits | Net (should be ≥ 0) |
|---|---|---|---|
| Dec/2025 | 2,709 | 5,410 | **-2,701** |
| Jan/2026 | 3,791 | 7,229 | **-3,438** |
| Feb/2026 | 11,444 | 22,063 | **-10,619** |

### 3. Order Approval Lead Time Analysis

Mapped the full approval workflow from the CRM's audit log table:

| Metric | Value |
|---|---|
| Median approval time | **16.8 hours** |
| Mean approval time | 84.2 hours (skewed by outliers) |
| Same-day approval (<24h) | 63% of orders |
| 5+ days (bottleneck) | 13% of orders |
| Currently blocked | 183 orders |

### 4. CFOP/Tax Operation Mapping

Reverse-engineered all 20 fiscal operation codes used in 2026 and classified them:

| Code | Description | Include in Sales? | Volume |
|---|---|---|---|
| 1 | SALE | Yes | 2,852 invoices / $53M |
| 8 | INTER-BRANCH TRANSFER | No (double-count!) | 1,395 / $7.6M |
| 5 | FREE SAMPLES | No | 190 / $549K |
| 11 | SCRAP SALE | Yes | 13 / $1.2M |
| 13 | EXPORT | Yes | 2 / $538K |

### 6. Real Order Entry Dates via Audit Log

Discovered that `crm_pedido.dat_emis_pedido` is overwritten every time an order is edited in the ERP — making it useless for "when did this order arrive?" analysis. Found that the `crm_audit` table (the ERP's internal change log) records a reliable `'pedido criado'` event at creation time. Rewrote the orders query to join `crm_audit` twice (once for creation event, once for quote→order conversion) and use `COALESCE(data_criacao, data_conversao)` as the authoritative entry date. Validated result matched the team's manual Excel reference to the day.

### 7. Daily Snapshot Script for Point-in-Time KPIs

Designed a Python snapshot concept that runs each morning before the BI is opened, querying live stock and backlog from the ERP and appending a row to a CSV file. This enables KPI cards showing "stock as of today" without requiring the BI to do expensive real-time queries, and accumulates a historical series for trend charts. Data is written as integers (no decimal point) to avoid locale-parsing issues in Brazilian Portuguese Power BI installations.

### 5. Liters Conversion Discovery

The ERP stores **liters per package** in a field originally designed for **specific gravity** (density). This is a local adaptation — the field `val_pes_espec` in the `peso_especifico` table stores `20` for a 20L pail (not `0.87 kg/L` as the field name suggests).

```sql
-- What the field name suggests: density in kg/L
-- What it actually stores: liters per package unit
-- PA00400 (20L pail):  val_pes_espec = 20  (not 0.87)
-- PA00613 (200L drum): val_pes_espec = 200 (not 0.87)
```

## Tech Stack

- **Database:** PostgreSQL (read-only access — no CREATE TABLE/VIEW permissions)
- **BI Tool:** Power BI Desktop (Import mode via ODBC)
- **ERP:** Datasul/Progress (DAGDA) on Genero Application Server
- **Secondary ERP:** SAP Business One (HANA) for legacy data
- **Languages:** SQL (advanced), DAX, Power Query M, Python (data processing)

## Project Structure

```
sql/
  views/           — 7 SQL queries (SELECT statements for PBI import)
  investigations/  — Ad-hoc investigation queries (inventory, lead time)
  dimensions/      — Dimension queries (company, customer, product)
docs/
  architecture.md     — System architecture and data flow
  gotchas.md          — ERP-specific pitfalls and workarounds (~20 entries)
  cfop-mapping.md     — Fiscal operation code classification
  corrections-log.md  — 8 documented bugs found and fixed during the build
analysis/
  inventory-ghost/ — Phantom stock investigation results
  lead-time/       — Approval workflow analysis
```

## Key Learnings

1. **Legacy ERPs have two naming conventions** — classic tables use `cod_` prefix (`cod_item`, `cod_cliente`), modern tables don't (`item`, `cliente`). Every cross-family JOIN needs a "translator" in the ON clause.

2. **Date sentinel `1900-01-01`** means NULL in Progress/Datasul heritage. Always wrap with `NULLIF(field, '1900-01-01'::timestamp)`.

3. **Read-only databases force creativity** — all transformation happens in the consumer (Power BI), not in the database. SQL views become Power Query native queries via `Odbc.Query()`.

4. **Inter-company transfers are the #1 source of revenue double-counting** in multi-branch setups. A CFOP whitelist + client exclusion list is more reliable than blacklisting specific operation codes.

5. **Warehouse address vs. location are different concepts** — `cod_local = 'EXPED'` (location) with `endereco = 'PRD'` (address) means "physically in expedition area but logically in production buffer."

6. **`crm_audit` is the source of truth for order dates** — editable date fields (`dat_emis_pedido`) get overwritten on every save. The audit log is append-only and preserves the original creation timestamp.

7. **`familia` table is required for product family segmentation** — `linha_prod` only exposes a generic category. The `familia` table (also multi-company, requiring a `GROUP BY` subquery) provides the Lubricants vs. Coolants vs. other segment split needed for business reporting.

## Author

**Warner Wladir Martin**
Analytics Engineer | Manufacturing & Distribution Data

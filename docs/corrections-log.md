# Corrections Log

This file documents bugs found and corrected during the BI build process. Each entry records the symptom, root cause, and fix applied. Kept as a portfolio artifact showing investigative rigor.

---

## Round 1 — 2026-04-10

### C1: Production Liters Inflated 11x

**Symptom:** `fat_apontamentos` returned 7.21 million liters produced. Expected ~628K based on manual reports.

**Root cause (5 compounding errors):**
1. No `cod_empresa` filter — query pulled production postings from all 22 companies instead of only the factory (empresa 01).
2. No `ies_tip_item` filter — included raw materials, semi-finished, and purchased items alongside finished goods.
3. `linha_prod` joined directly without subquery — table has no `cod_empresa` column, causing a silent cartesian product when duplicate `cod_lin_prod` values exist.
4. `peso_especifico` joined without fixing `cod_empresa` — table stores one row per company per item (22 rows per item), multiplying every liter calculation by up to 22.
5. No `GROUP BY` — query returned one row per individual movement transaction instead of aggregating by item + day + movement type.

**Fix:** Added `WHERE cod_empresa = '01'` and `ies_tip_item = 'F'`, rewrote `linha_prod` JOIN as a deduplicating subquery, fixed `peso_especifico` to `cod_empresa = '01'`, added `GROUP BY cod_empresa, dat_movto::date, cod_item, ies_tip_movto`.

**Result:** 628K liters — matches PRD0157 report.

---

### C2: Snapshot CSV Values 10x Too Large in Power BI

**Symptom:** KPI cards showed ~62 million liters in stock. Actual stock ~6.2 million liters (10x inflation).

**Root cause:** The Python snapshot script wrote float values with a period as decimal separator (`624285.63`). Power BI running under a Brazilian Portuguese Windows locale interpreted the period as a thousands separator, reading `624285.63` as `624,285,630`.

**Fix:** Changed the Python script to write rounded integers (`int(round(x, 0))`) — no decimal point, no locale ambiguity.

**Result:** KPI cards show correct values.

---

### C3: Production vs. Billing Chart Lines Did Not Cross

**Symptom:** The "Production vs. Billing Accumulated" line chart showed two parallel lines that never intersected, making comparison meaningless.

**Root cause:** "Litros Produzidos" was placed on the secondary Y axis, while "Litros Faturados" was on the primary Y axis. The two scales were independent, so visual crossing had no analytical meaning.

**Fix:** Moved both measures to the primary Y axis so they share the same scale.

---

### C4: Accumulated Measures Showed Flat Line After Last Data Point

**Symptom:** Accumulated line charts (Litros Faturados Acum, Entrada Pedidos Acum, etc.) continued horizontally after the last date with actual data, making it look like activity stopped.

**Root cause:** DAX accumulation pattern did not handle future dates — `CALCULATE` with a date filter up to current context date still returned the last real value for every future date in the calendar.

**Fix:** Added a guard to all `*Acum` measures:
```dax
VAR UltimoDado = MAXX(fat_vendas, fat_vendas[data_emissao])
RETURN IF(DataAtual > UltimoDado, BLANK(), <accumulated calc>)
```
`BLANK()` causes Power BI to drop the data point, breaking the line instead of extending it flat.

---

### C5: Packaging Breakdown Charts Showed Identical Bars

**Symptom:** The "Production by Packaging" chart showed four bars (BD, CX, TB, IBC) with identical heights.

**Root cause:** The axis field was `dim_item[un]` — connected to `fat_apontamentos` through a relationship via `cod_item`. Because `dim_item` has one row per item regardless of packaging type, the relationship forced all packaging types to show the same total.

**Fix:** Changed axis field to `fat_apontamentos[un]` (direct column on the fact table, no relationship hop). Applied the same fix to `fat_estoque_oleo[un]` on the stock chart.

---

## Round 2 — 2026-04-13 / 2026-04-14

### C6: Order Entry Dates Were Wrong (Edited-Date Problem)

**Symptom:** "Entrada de Pedidos" chart showed spikes on wrong dates. Validation against the team's Excel reference showed mismatches of several days per order, with no consistent pattern.

**Root cause:** `crm_pedido.dat_emis_pedido` and `dat_emis_repres` are overwritten every time an order is edited in the ERP. An order entered on April 1st that gets a delivery-date change on April 10th will show April 10th as its emission date — incorrect for intake analysis.

**Investigation:** Queried `crm_audit` (the ERP's internal audit log) for the `CRM_PEDIDO` table. Found two reliable event types:
- `AUDITMSG LIKE '%pedido%criado%'` — logged exactly once when the order is first created.
- `IES_TIPO = 'P'` — logged when a quote is converted to an order (for the quote→order workflow).

**Fix:** Rewrote `03_fat_pedidos.sql` with two LEFT JOIN subqueries on `crm_audit`, taking `MIN(datahora)` from each. Applied `COALESCE(data_pedido, data_conversao)` as the authoritative entry date.

**Validation:** April 1st total = 88,036 liters. Matches the team's Excel reference exactly.

---

### C7: Suspended Orders Duplicating Intake Totals

**Symptom:** After fixing dates (C6), some day totals were still higher than the Excel reference. Specific orders appeared to be counted twice.

**Root cause:** Orders with `ies_suspenso = 'S'` are an internal ERP process (used to hold orders across fiscal periods or for internal allocation). These orders have a corresponding "real" order — both share the same items and quantities, causing double-counting in any simple SUM.

**Fix:** Added `AND (cp.ies_suspenso IS NULL OR cp.ies_suspenso <> 'S')` to the WHERE clause of `03_fat_pedidos.sql`.

---

### C8: Filtering `ies_sit_pedido` Dropped Historical Orders

**Symptom:** An earlier version of the query filtered `ies_sit_pedido IN ('A', 'P')` to keep only active/pending orders. This made the Carteira (backlog) view correct but caused the "Entrada de Pedidos" historical chart to lose fulfilled and cancelled orders — making intake appear lower than the Excel reference.

**Root cause:** `ies_sit_pedido` reflects current status, not historical status at entry time. Filtering by it removes all orders that have since been invoiced or cancelled, which are valid data points for an intake-over-time analysis.

**Fix:** Removed the `ies_sit_pedido` filter entirely. Orders already invoiced remain in the dataset (correctly showing their intake contribution) while the `em_aberto` flag and `qtd_saldo` column handle the backlog view separately.

---

## Summary Table

| # | Date | Query Affected | Symptom | Fix |
|---|---|---|---|---|
| C1 | 2026-04-10 | fat_apontamentos | Liters 11x too high | empresa filter + ies_tip_item + GROUP BY + subquery fixes |
| C2 | 2026-04-10 | historico_snapshots.csv | KPI values 10x too high | Write integers from Python, not floats |
| C3 | 2026-04-10 | Power BI chart | Lines never crossed | Move both series to primary Y axis |
| C4 | 2026-04-10 | All *Acum DAX measures | Flat line after last data | Add BLANK() guard for future dates |
| C5 | 2026-04-10 | Power BI chart | Identical packaging bars | Use fact table [un] column, not dim_item |
| C6 | 2026-04-13 | fat_pedidos | Wrong order dates | Use crm_audit for real entry date |
| C7 | 2026-04-13 | fat_pedidos | Double-counted orders | Filter ies_suspenso <> 'S' |
| C8 | 2026-04-14 | fat_pedidos | Historical intake missing fulfilled orders | Remove ies_sit_pedido filter |

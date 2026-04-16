# System Architecture

## Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│              PostgreSQL (ERP — Read-Only)                     │
│                                                               │
│  Fact Tables:                                                 │
│    fat_nf_mestre + fat_nf_item    (Invoices)                  │
│    crm_pedido + crm_pedido_item   (Orders + backlog)          │
│    crm_pedido_log_aprovacao       (Approval audit trail)      │
│    estoque_lote_ender             (Inventory by lot/address)  │
│    vw_estoque_trans               (Stock movements)           │
│                                                               │
│  Dimension Tables:                                            │
│    empresa (22 companies), clientes, cidades                  │
│    item, linha_prod, nat_operacao                              │
│    peso_especifico (liters per package)                        │
│    obr_produto_anp (regulatory ANP classification)             │
│                                                               │
│  Access: SELECT only via ODBC (PostgreSQL Unicode driver)     │
└─────────────────────────────────────────────────────────────┘
                              │
                              │  Odbc.Query() via Power Query M
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   Power BI Desktop (Import)                    │
│                                                               │
│  7 SQL queries imported as tables                             │
│  1 CSV lookup (company classification)                        │
│  1 DAX calendar table                                         │
│  ~25 DAX measures + 4 calculated columns                      │
│  7 report pages (dashboard MVP)                               │
└─────────────────────────────────────────────────────────────┘
```

## Company Structure (22 Business Units)

| Type | Count | Codes |
|---|---|---|
| Oil Factory (HQ) | 1 | `01` — only unit that manufactures lubricant oil |
| Packaging Plant | 1 | `06` — manufactures plastic packaging |
| Commercial Branches | 18 | `02-05, 07-17, 19, 21-22` — receive goods via inter-company transfer, sell to end customers |
| Distributor | 1 | `50` — separate legal entity |
| Non-Commercial | 1 | `30` — no sales activity |

## Anti-Duplication Logic

Factory (01) produces and ships to branches via **transfer invoices** (CFOP code 8). Branches then sell to customers via **sale invoices** (CFOP code 1). Without filtering, the same physical unit gets counted twice.

**Solution — Triple Check:**
1. CFOP whitelist: `natureza_operacao IN (1, 11, 13)` — only real sales
2. Status filter: `sit_nota_fiscal = 'N'` — excludes cancelled
3. Client filter: `cliente NOT IN (SELECT cod_cliente FROM empresa)` — excludes inter-company

## Warehouse Address Map

Within the `EXPED` (expedition) location:

| Address | Purpose | Monitor? |
|---|---|---|
| `BLC.01` | Main storage (picked and ready) | Normal |
| `PRD` | Production buffer (post-posting, pre-transfer) | ⚠️ Accumulates phantom stock |
| `CON` | Picking/shipping buffer (normal flow) | Normal |
| `AVA` | Damaged goods | ⚠️ Used as pass-through to offset PRD leaks |
| `REC` | Returns receiving | Normal |

## DAX Measures Architecture

| Category | Measures | Table |
|---|---|---|
| Base metrics | Total Liters, Total Revenue, Invoice Count, Client Count, Avg Price/Liter | fat_vendas |
| Time intelligence | YTD Liters/Revenue, Month-over-Month %, Year-over-Year %, Prior Month | fat_vendas |
| Customer status | Last Invoice Date, Days Without Purchase, Status (Active/At Risk/Inactive) | dim_cliente |
| Customer ABC | Historical Value, Ranking, Cumulative %, Classification (A/B/C) | dim_cliente (calc columns) |
| Orders | Backlog Value/Liters, Open Orders Count, Margin %, Avg Ticket | fat_pedidos |
| Inventory | Liters in Stock, Active Lots, Avg Lot Age, Oldest Lot | fat_estoque_oleo |
| Production | Liters Produced, Posting Count, Avg per Posting | fat_apontamentos |

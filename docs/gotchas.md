# ERP Gotchas & Workarounds

Hard-won lessons from working with a legacy Datasul/Progress ERP running on PostgreSQL.

## 1. Two Naming Conventions Coexist

**Classic tables** (`item`, `clientes`, `empresa`, `nat_operacao`) use `cod_` prefix:
- `cod_empresa`, `cod_item`, `cod_cliente`, `cod_nat_oper`

**Modern tables** (`fat_nf_mestre`, `fat_nf_item`) use clean names:
- `empresa`, `item`, `cliente`, `natureza_operacao`

Every cross-family JOIN needs a "translator":
```sql
-- fat_nf_item.item (modern) = item.cod_item (classic)
LEFT JOIN item i ON i.cod_item = nfi.item AND i.cod_empresa = nfi.empresa
```

## 2. Date Sentinel: 1900-01-01

Empty dates are stored as `1900-01-01 00:00:00` (Progress/Datasul heritage), not NULL.

```sql
NULLIF(e.dat_hor_producao, '1900-01-01 00:00:00'::timestamp) AS production_date
```

## 3. Specific Gravity Field Stores Liters

The `peso_especifico.val_pes_espec` field is **supposed** to store density (kg/L). In this implementation, it stores **liters per package**:

| Item | Field Value | Actual Meaning |
|---|---|---|
| 20L Pail | 20.000000 | 20 liters (NOT 20 kg/L!) |
| 200L Drum | 200.000000 | 200 liters |
| 24x1L Case | 24.000000 | 24 liters |

Correct weight per item is in `item.pes_unit` (18.30 kg for a 20L pail of oil).

## 4. Ghost Tables

The `pedido` table (73 columns) is **completely empty**. Real orders live in `crm_pedido` + `crm_pedido_item`. Similarly, `ped_itens` and `pedidos` are legacy copies with ~95% overlap — ignore them.

## 5. Fields That Exist But Are Never Populated

- `fat_nf_item.uni_med_trib` / `qtd_item_trib` — 100% NULL. Cannot be used for unit conversion.
- `fat_nf_mestre.tip_venda` and `crm_pedido.cod_tip_venda` — only value `1` in 99.7% of records. Useless as sales channel indicator.
- `obr_produto_anp.massa_especif` — 100% empty. Real density never registered.

## 6. Customer PK is the Tax ID (CNPJ)

`clientes.cod_cliente` is the formatted CNPJ (`038248576000226`), not a sequential number. Each group company also has a customer record — this is how inter-company invoices work. The `empresa.cod_cliente` field points to the company's "mirror" customer.

## 7. Warehouse Location vs. Address

These are **different concepts** in the ERP:

| Field | Example | Meaning |
|---|---|---|
| `cod_local` | `EXPED` | Physical warehouse (expedition area) |
| `endereco` | `PRD`, `BLC.01`, `AVA`, `CON` | Address/slot within the warehouse |

A product can be in `EXPED.PRD` (expedition location, production address) — meaning it's physically in the expedition area but logically still in the production buffer.

## 8. Read-Only Database

No `CREATE TABLE`, `CREATE VIEW`, or any DDL. All transformation must happen in the consumer (Power BI, Excel). SQL views become native queries via `Odbc.Query()` in Power Query.

## 9. Invoice Number in SAP B1 (HANA)

If querying the secondary ERP (SAP B1 on HANA), the invoice number is **`OINV.Serial`**, not `OINV.DocNum` (which is the internal document number) and not `OINV.FolioNumber` (which doesn't exist in this installation).

## 10. Stock Movement Operation Codes

| Code | Meaning | Characteristics |
|---|---|---|
| `APON` | Production posting | Origin empty, lot in destination only. Program: `PRD1011` |
| `TRAN` | Internal transfer | Origin and destination filled. Programs: `VSC0009`, `VSC0240` |
| `TRAS` | Pre-invoice transfer | Exit without physical destination. Program: `FAT1878` |
| `VEND` | Sale (fiscal exit) | Exit with order reference. Program: `FAT1878` |
| `BAIX` | Consumption (raw material) | Used for bulk/granel consumption during packaging |
| `AJS+`/`AJS-` | Manual adjustment | Program: `ent0349` |
| `INV+`/`INV-` | Inventory adjustment | Program: `ENT1661` |

Movement type flag: `N` = Normal, `R` = Reversal/Cancellation.

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

`clientes.cod_cliente` is the formatted CNPJ (`01234567890123`), not a sequential number. Each group company also has a customer record — this is how inter-company invoices work. The `empresa.cod_cliente` field points to the company's "mirror" customer.

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

## 11. Order Entry Dates Are Overwritten on Edit

`crm_pedido.dat_emis_pedido` and `dat_emis_repres` are **overwritten every time an order is edited** — they do not represent the real entry date. To get the true order creation date, query the `crm_audit` log table:

```sql
-- Real creation date: when audit logged 'pedido criado'
SELECT
    substring(chave,1,2)                    AS cod_empresa,
    rtrim(ltrim(substring(chave,4,6)))::int  AS num_pedido,
    MIN(datahora)::date                      AS data_pedido
FROM crm_audit
WHERE nom_tabela = 'CRM_PEDIDO'
  AND campo      = 'AUDITMSG'
  AND lower(new_val) LIKE '%pedido%criado%'
GROUP BY substring(chave,1,2), rtrim(ltrim(substring(chave,4,6)))::int
```

Use `COALESCE(data_pedido, data_conversao)` where `data_conversao` is the moment `ies_tipo` changed to `'P'` (quote converted to order).

## 12. `linha_prod` Has No `cod_empresa` Column

Unlike most master tables, `linha_prod` is not scoped by company. A direct JOIN can cause silent cartesian products if there are duplicate `cod_lin_prod` values across loaded data. Always use a subquery with `GROUP BY` and `MAX()`:

```sql
LEFT JOIN (
    SELECT cod_lin_prod, MAX(den_estr_linprod) AS den_estr_linprod
    FROM linha_prod
    GROUP BY cod_lin_prod
) lp ON lp.cod_lin_prod = i.cod_lin_prod
```

## 13. `peso_especifico` Has One Row per Company (22 rows per item)

The `peso_especifico` table stores the liters-per-package value per company. A join without a company filter multiplies every row by 22, silently inflating all liter totals. Always fix to a single company:

```sql
LEFT JOIN peso_especifico pe
  ON pe.cod_empresa = '01'    -- fix to the producing company
 AND pe.cod_item    = e.cod_item
```

## 14. `familia` Table Also Has 22 Rows per Family

Same issue as `peso_especifico` — the `familia` table has one row per `(cod_empresa, cod_familia)`. To get a unique family description, use a subquery:

```sql
LEFT JOIN (
    SELECT cod_empresa, cod_familia, MAX(den_familia) AS den_familia
    FROM familia GROUP BY cod_empresa, cod_familia
) fam ON fam.cod_empresa = cp.cod_empresa
     AND fam.cod_familia  = i.cod_familia
```

Use `familia` for Lubricants vs. Coolants classification — `linha_prod` only contains a generic "GENERAL" category and cannot distinguish product families.

## 15. `ies_suspenso` and `ies_sit_pedido` Are Two Separate Fields

Suspended orders (`ies_suspenso = 'S'`) are an internal process that duplicates orders — they must be excluded. `ies_sit_pedido` is a different field representing billing status. Both need to be checked independently; filtering on only one will still produce inflated totals.

## 16. Do Not Filter `ies_sit_pedido` When Measuring Order Intake

Filtering by `ies_sit_pedido` to keep only "open" orders will exclude orders already fulfilled or cancelled — which means they disappear from the historical entry chart. For "Entrada de Pedidos" (order intake over time), include all statuses and rely only on `data_pedido` from `crm_audit`.

## 17. `ies_tipo` Is the Correct Field for Order vs. Quote

The field to distinguish quotes from orders is `ies_tipo` (values: `'O'` = orcamento/quote, `'P'` = pedido/order). The field `ies_tip_pedido` is a different attribute (order type classification) and should not be confused with it.

## 18. Stock Query Must Filter `cod_local = 'EXPED'` and Specific Addresses

Without `cod_local = 'EXPED'`, the stock query picks up locations like `DEVOL` (returns) and `IC` (inter-company), inflating finished goods stock. Within `EXPED`, further filter `endereco IN ('BLC.01', 'PRD')` to exclude `AVA` (damaged), `CON` (consigned), and `REC` (receiving). Missing these two filters was responsible for ~130K liters of phantom stock.

## 19. Finished Goods Stock Includes Type `B` (Beneficiado)

`ies_tip_item = 'F'` (Fabricado) alone misses items classified as `'B'` (Beneficiado/toll-manufactured), which are part of the real finished goods inventory. Use `ies_tip_item IN ('F', 'B')` for stock and production queries.

## 20. ICONIC Items Need a Separate Packaging Category

Items with "ICONIC" in their product line name have unit of measure `CX` (box) but represent a premium package that must be tracked separately. Create a calculated column in Power BI to detect them:

```dax
embalagem_cat = IF(SEARCH("ICONIC", fat_apontamentos[linha_produto], 1, 0) > 0,
                   "ICONIC",
                   fat_apontamentos[un])
```

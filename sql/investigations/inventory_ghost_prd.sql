-- =============================================================================
-- Inventory Ghost Investigation — PRD Address
-- =============================================================================
-- Discovered ~130K liters of phantom stock in the PRD (production) address
-- within the EXPED (expedition) warehouse location.
--
-- Root cause: Logistics physically moves products from PRD to BLC.01 (main
-- storage block) but fails to register the transfer in the system (VSC0009).
-- This creates a ~2-3% leak per cycle that accumulates over months.
--
-- Additionally, the system auto-feeds AVA (damaged goods) and CON (returns)
-- addresses from customer return invoices. Logistics then "borrows" AVA/CON
-- balances to offset the PRD gap — creating a laundering pattern where AVA
-- consistently shows negative net flow (impossible in a real inventory).
-- =============================================================================


-- Step 1: Current snapshot of PRD address
-- Shows all lots currently stuck in PRD with quantities and days since last movement

SELECT
    e.cod_item,
    i.den_item,
    e.num_lote,
    e.qtd_saldo                                             AS saldo_prd,
    e.qtd_saldo * COALESCE(pe.val_pes_espec, 0)             AS litros_prd,
    SUM(CASE WHEN t.cod_operacao = 'APON' AND t.ies_tip_movto = 'N'
             AND t.endereco = 'PRD'
             THEN t.qtd_movto ELSE 0 END)                    AS entrada_prd,
    SUM(CASE WHEN t.cod_operacao = 'TRAN' AND t.ies_tip_movto = 'N'
             AND t.endereco_origem = 'PRD'
             THEN t.qtd_movto ELSE 0 END)                    AS saida_prd,
    MAX(t.dat_movto)                                         AS ultimo_movimento,
    CURRENT_DATE - MAX(t.dat_movto)                          AS dias_parado
FROM estoque_lote_ender e
JOIN item i ON i.cod_empresa = e.cod_empresa AND i.cod_item = e.cod_item
LEFT JOIN peso_especifico pe ON pe.cod_empresa = e.cod_empresa AND pe.cod_item = e.cod_item
LEFT JOIN vw_estoque_trans t
  ON t.cod_empresa = e.cod_empresa
 AND t.cod_item = e.cod_item
 AND (t.num_lote_orig = e.num_lote OR t.num_lote_dest = e.num_lote)
 AND (t.endereco = 'PRD' OR t.endereco_origem = 'PRD')
WHERE e.cod_empresa = '01'
  AND e.cod_local = 'EXPED'
  AND e.endereco = 'PRD'
  AND e.qtd_saldo > 0
GROUP BY e.cod_item, i.den_item, e.num_lote, e.qtd_saldo,
         COALESCE(pe.val_pes_espec, 0)
ORDER BY litros_prd DESC;


-- Step 2: Monthly entry vs exit balance for AVA (proves the laundering pattern)
-- A healthy inventory address should NEVER have exits > entries consistently.

SELECT
    TO_CHAR(t.dat_movto, 'YYYY-MM')                         AS mes,
    CASE WHEN t.endereco IN ('AVA','CON') THEN t.endereco
         ELSE t.endereco_origem END                          AS endereco,
    SUM(CASE WHEN t.endereco IN ('AVA','CON')
             THEN t.qtd_movto ELSE 0 END)                    AS entradas,
    SUM(CASE WHEN t.endereco_origem IN ('AVA','CON')
             THEN t.qtd_movto ELSE 0 END)                    AS saidas,
    SUM(CASE WHEN t.endereco IN ('AVA','CON') THEN t.qtd_movto ELSE 0 END)
    - SUM(CASE WHEN t.endereco_origem IN ('AVA','CON') THEN t.qtd_movto ELSE 0 END)
                                                             AS saldo_liquido
FROM vw_estoque_trans t
WHERE t.cod_empresa = '01'
  AND (t.endereco IN ('AVA','CON') OR t.endereco_origem IN ('AVA','CON'))
  AND t.ies_tip_movto = 'N'
  AND t.dat_movto >= '2025-01-01'
GROUP BY TO_CHAR(t.dat_movto, 'YYYY-MM'),
    CASE WHEN t.endereco IN ('AVA','CON') THEN t.endereco ELSE t.endereco_origem END
ORDER BY endereco, mes;


-- Step 3: Flow classification — where do AVA exits actually go?
-- If most exits go to BLC.01 (main storage), it confirms pass-through usage.

SELECT
    t.endereco_origem                                        AS saiu_de,
    t.endereco                                               AS foi_pra,
    t.cod_operacao,
    t.num_prog,
    CASE
        WHEN t.endereco = 'BLC.01' THEN 'RETURNED_TO_STOCK'
        WHEN t.endereco = 'PRD'    THEN 'RETURNED_TO_PRODUCTION'
        WHEN t.cod_operacao IN ('VEND','TRAS') THEN 'SHIPPED_OUT'
        WHEN t.cod_operacao IN ('AJS-','INV-') THEN 'WRITTEN_OFF'
        ELSE 'OTHER'
    END                                                      AS destination_type,
    COUNT(*)                                                 AS movement_count,
    SUM(t.qtd_movto)                                         AS total_units
FROM vw_estoque_trans t
WHERE t.cod_empresa = '01'
  AND t.endereco_origem IN ('AVA','CON')
  AND t.ies_tip_movto = 'N'
  AND t.dat_movto >= '2025-01-01'
GROUP BY t.endereco_origem, t.endereco, t.cod_operacao, t.num_prog,
    CASE
        WHEN t.endereco = 'BLC.01' THEN 'RETURNED_TO_STOCK'
        WHEN t.endereco = 'PRD'    THEN 'RETURNED_TO_PRODUCTION'
        WHEN t.cod_operacao IN ('VEND','TRAS') THEN 'SHIPPED_OUT'
        WHEN t.cod_operacao IN ('AJS-','INV-') THEN 'WRITTEN_OFF'
        ELSE 'OTHER'
    END
ORDER BY saiu_de, total_units DESC;

-- =============================================================================
-- Order Approval Lead Time Analysis
-- =============================================================================
-- Maps the full approval workflow from the CRM audit log table.
-- Each order goes through FINANCIAL and COMMERCIAL approval before becoming
-- available to logistics for picking/shipping.
--
-- Key findings (Q1 2026):
--   Median lead time: 16.8 hours (63% same-day)
--   Mean lead time: 84.2 hours (skewed by outliers)
--   Bottleneck: 13% of orders take 5+ days (mostly cash-on-delivery awaiting payment)
-- =============================================================================


-- Approval types in the audit log:
--   COMERC = Commercial approval/block
--   FINANC = Financial approval/block
--   ANTECI = Advance payment approval/block
--
-- Function codes:
--   B = Blocked (order enters blocked state)
--   A = Approved (someone approved and released)
--   R = Rejected
--   S = Suspended


-- Main query: Lead time per order

SELECT
    cp.cod_empresa,
    cp.num_pedido,
    cp.cod_cliente                                          AS cliente_cnpj,
    c.nom_cliente                                           AS cliente,
    cp.dat_emis_pedido::date                                AS data_emissao,
    cp.dat_prazo_entrega::date                              AS data_prazo,

    -- First block timestamp
    MIN(CASE WHEN la.funcao_aprovacao = 'B'
             THEN la.data_aprovacao END)::timestamp(0)       AS primeiro_bloqueio,

    -- Last approval timestamp = when order became available to logistics
    MAX(CASE WHEN la.funcao_aprovacao = 'A'
             THEN la.data_aprovacao END)::timestamp(0)       AS ultima_aprovacao,

    -- Status classification
    CASE
        WHEN MAX(CASE WHEN la.funcao_aprovacao = 'A'
                      THEN la.data_aprovacao END) IS NOT NULL
        THEN 'RELEASED'
        WHEN MAX(CASE WHEN la.funcao_aprovacao = 'B'
                      THEN la.data_aprovacao END) IS NOT NULL
        THEN 'BLOCKED'
        ELSE 'NO_APPROVAL_NEEDED'
    END                                                      AS approval_status,

    -- Lead time in hours (emission to final approval)
    EXTRACT(EPOCH FROM (
        MAX(CASE WHEN la.funcao_aprovacao = 'A'
                 THEN la.data_aprovacao END)
        - cp.dat_emis_pedido
    )) / 3600.0                                              AS lead_time_hours,

    -- Current block status
    cp.bloqueio_financeiro                                   AS bloq_fin_atual,
    cp.bloqueio_comercial                                    AS bloq_com_atual

FROM crm_pedido cp
LEFT JOIN crm_pedido_log_aprovacao la
  ON la.cod_empresa = cp.cod_empresa
 AND la.num_pedido  = cp.num_pedido
LEFT JOIN clientes c
  ON c.cod_cliente = cp.cod_cliente
WHERE cp.dat_emis_pedido >= '2026-01-01'
GROUP BY cp.cod_empresa, cp.num_pedido, cp.cod_cliente, c.nom_cliente,
         cp.dat_emis_pedido, cp.dat_prazo_entrega,
         cp.bloqueio_financeiro, cp.bloqueio_comercial
ORDER BY cp.dat_emis_pedido DESC;

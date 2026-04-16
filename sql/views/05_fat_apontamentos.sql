-- =============================================================================
-- 05_fat_apontamentos.sql
-- =============================================================================
-- Apontamentos de producao (substitui/apura o PRD0157)
-- Power BI: Obter Dados -> PostgreSQL -> Avancado -> colar esta query
-- Nome sugerido da query: fat_apontamentos
--
-- APON = operacao de apontamento de producao (detectada via vw_estoque_trans).
-- Filtrado para:
--   - cod_empresa = '01' (MTZ, unica produtora de oleo)
--   - ies_tip_item = 'F' (somente itens FINAIS/Fabricados)
-- GROUP BY por item+dia+tipo para evitar duplicatas e agregar litragem.
--
-- ATENCAO:
--   - linha_prod NAO tem coluna cod_empresa -> usar subquery com GROUP BY
--   - peso_especifico tem 22 linhas por item -> sempre fixar cod_empresa='01'
--
-- CORRECOES APLICADAS:
--   1. Adicionado GROUP BY -- versao original retornava 1 linha por movimento
--      individual, causando total de 7,21 Mi litros (deveria ser ~628K).
--   2. cod_empresa = '01' -- versao original trazia todas as 22 empresas.
--   3. ies_tip_item = 'F' -- versao original incluia todos os tipos de item.
--   4. linha_prod via subquery -- tabela linha_prod nao tem cod_empresa,
--      JOIN direto causava produto cartesiano silencioso.
--   5. peso_especifico fixado cod_empresa='01' -- sem fixar, JOIN retornava
--      ate 22 linhas por item (1 por empresa) inflando litros.
-- =============================================================================

SELECT
    e.cod_empresa,
    e.dat_movto::date                        AS data_apontamento,
    e.cod_item,
    MAX(i.den_item)                          AS den_item,
    MAX(i.cod_unid_med)                      AS un,
    MAX(lp.den_estr_linprod)                 AS linha_produto,
    e.ies_tip_movto                          AS tipo_movto,

    -- quantidade liquida (N=entrada, R=estorno negativo)
    SUM(CASE WHEN e.ies_tip_movto = 'N' THEN  e.qtd_movto
             WHEN e.ies_tip_movto = 'R' THEN -e.qtd_movto
             ELSE 0 END)                     AS qtd_liquida,

    -- litragem liquida (qtd x peso especifico)
    SUM(CASE WHEN e.ies_tip_movto = 'N'
             THEN  e.qtd_movto * COALESCE(pe.val_pes_espec, 0)
             WHEN e.ies_tip_movto = 'R'
             THEN -e.qtd_movto * COALESCE(pe.val_pes_espec, 0)
             ELSE 0 END)                     AS litros_liquidos

FROM vw_estoque_trans e

JOIN item i
  ON i.cod_empresa = e.cod_empresa
 AND i.cod_item    = e.cod_item

-- linha_prod nao tem cod_empresa -> subquery com MAX para deduplicar
LEFT JOIN (
    SELECT cod_lin_prod, MAX(den_estr_linprod) AS den_estr_linprod
    FROM linha_prod
    GROUP BY cod_lin_prod
) lp ON lp.cod_lin_prod = i.cod_lin_prod

-- peso_especifico: fixar empresa '01' para evitar 22x duplicacao
LEFT JOIN peso_especifico pe
  ON pe.cod_empresa = '01'
 AND pe.cod_item    = e.cod_item

WHERE e.cod_operacao = 'APON'
  AND e.cod_empresa   = '01'        -- somente MTZ
  AND i.ies_tip_item  = 'F'         -- somente itens Finais/Fabricados

GROUP BY e.cod_empresa, e.dat_movto::date, e.cod_item, e.ies_tip_movto

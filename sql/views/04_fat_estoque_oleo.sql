-- =============================================================================
-- 04_fat_estoque_oleo.sql
-- =============================================================================
-- Saldo de estoque por lote + data real de producao (via primeiro APON)
-- Power BI: Obter Dados -> PostgreSQL -> Avancado -> colar esta query
-- Nome sugerido da query: fat_estoque_oleo
--
-- FILTRADO EMPRESA 01 (MTZ) -- unica produtora de oleo da Energy.
-- Para estoque de embalagens (empresa 06), criar uma query irma
-- trocando o filtro e apontando pro cadastro da propria 06.
--
-- CORRECOES APLICADAS (descobertas durante validacao):
--   1. cod_local = 'EXPED' obrigatorio -- sem este filtro inclui locais DEVOL,
--      IC e outros que nao representam estoque acabado comercializavel.
--   2. endereco IN ('BLC.01', 'PRD') -- filtra apenas estoque acabado (BLC.01)
--      e em producao (PRD). Exclui AVA (avaria), CON (consignado), REC
--      (recebimento) que distorciam o saldo total em ~130K litros.
--   3. ies_tip_item IN ('F', 'B') -- inclui Fabricado E Beneficiado.
--      Filtrar so 'F' perdia embalagens beneficiadas que compoe estoque real.
-- =============================================================================

SELECT
    ele.cod_empresa,
    ele.cod_item,
    i.den_item,
    i.cod_unid_med                           AS un,
    i.cod_lin_prod,
    lp.den_estr_linprod                      AS linha_produto,
    ele.cod_local                            AS local_estoque,
    ele.num_lote                             AS lote,
    ele.endereco,

    -- saldo
    ele.qtd_saldo,
    ele.qtd_saldo * COALESCE(pe.val_pes_espec, 0) AS litros_saldo,

    -- datas de producao
    NULLIF(ele.dat_hor_producao, '1900-01-01 00:00:00'::timestamp) AS data_prod_cadastro,
    prod.data_producao_real

FROM estoque_lote_ender ele

JOIN item i
  ON i.cod_empresa = ele.cod_empresa
 AND i.cod_item    = ele.cod_item

LEFT JOIN linha_prod lp
  ON lp.cod_lin_prod = i.cod_lin_prod

-- Litragem direto do cadastro da MTZ
LEFT JOIN peso_especifico pe
  ON pe.cod_empresa = ele.cod_empresa
 AND pe.cod_item    = ele.cod_item

-- Data real de producao: primeiro apontamento do lote
LEFT JOIN (
    SELECT cod_empresa, cod_item, num_lote_dest AS num_lote,
           MIN(dat_movto) AS data_producao_real
    FROM vw_estoque_trans
    WHERE cod_operacao = 'APON'
      AND ies_tip_movto = 'N'
      AND num_lote_dest <> ''
    GROUP BY cod_empresa, cod_item, num_lote_dest
) prod
  ON prod.cod_empresa = ele.cod_empresa
 AND prod.cod_item    = ele.cod_item
 AND prod.num_lote    = ele.num_lote

WHERE ele.qtd_saldo > 0
  AND ele.cod_empresa = '01'                      -- MTZ (unica produtora de oleo)
  AND ele.cod_local = 'EXPED'                     -- somente expedicao (exclui DEVOL, IC)
  AND ele.endereco IN ('BLC.01', 'PRD')           -- estoque acabado + em producao (exclui AVA, CON, REC)
  AND i.ies_tip_item IN ('F', 'B')                -- Fabricado + Beneficiado (nao so F)

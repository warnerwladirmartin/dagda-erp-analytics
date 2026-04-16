-- =============================================================================
-- 07_dim_item.sql
-- =============================================================================
-- Dimensao de item (produto + linha + litragem consolidada)
-- Power BI: Obter Dados -> PostgreSQL -> Avancado -> colar esta query
-- Nome sugerido da query: dim_item
--
-- Traz 1 linha por (cod_empresa, cod_item). Usamos COALESCE pra consolidar
-- a litragem: cadastro local > fallback MTZ (01) > 0.
-- =============================================================================

SELECT
    i.cod_empresa,
    i.cod_item,
    i.den_item,
    i.den_item_reduz,
    i.cod_unid_med                            AS un,
    i.ies_tip_item                            AS tipo_item,   -- F=Fabricado, C=Comprado
    i.ies_situacao                            AS situacao,
    i.ies_ctr_estoque                         AS controla_estoque,
    i.ies_ctr_lote                            AS controla_lote,
    i.cod_familia,
    i.cod_lin_prod,
    lp.den_estr_linprod                       AS linha_produto,
    i.cod_lin_recei                           AS cod_linha_receita,
    i.cod_seg_merc                            AS cod_segmento_mercado,
    i.cod_cla_uso                             AS cod_classe_uso,
    i.pes_unit                                AS peso_unit_kg,                        -- peso REAL em kg
    COALESCE(pe.val_pes_espec, pe_mtz.val_pes_espec, 0) AS litros_por_embalagem       -- LITRAGEM adaptada
FROM item i
LEFT JOIN linha_prod lp
  ON lp.cod_lin_prod = i.cod_lin_prod
LEFT JOIN peso_especifico pe
  ON pe.cod_empresa = i.cod_empresa
 AND pe.cod_item    = i.cod_item
LEFT JOIN peso_especifico pe_mtz
  ON pe_mtz.cod_empresa = '01'
 AND pe_mtz.cod_item    = i.cod_item
WHERE i.ies_situacao = 'A'

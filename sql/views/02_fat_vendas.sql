-- =============================================================================
-- fat_vendas — Sales fact table (1 row per invoice line item)
-- =============================================================================
-- TRIPLE-CHECK anti-duplication filter applied:
--   (a) CFOP whitelist: only Sale (1), Scrap Sale (11), Export (13)
--   (b) Invoice status = 'N' (Normal, excludes cancelled)
--   (c) Customer NOT IN group companies (excludes inter-branch transfers)
--
-- Liters calculated via peso_especifico.val_pes_espec (locally adapted field
-- that stores liters-per-package, NOT actual density).
-- Fallback to HQ (empresa '01') if branch doesn't have the product registered.
-- =============================================================================

SELECT
    nfm.empresa                              AS cod_empresa,
    nfm.trans_nota_fiscal,
    nfi.seq_item_nf,

    -- Invoice
    nfm.nota_fiscal,
    nfm.natureza_operacao                    AS cod_nat_oper,
    no_.den_nat_oper                         AS nat_oper,
    nfm.dat_hor_emissao::date                AS data_emissao,
    nfm.dat_hor_saida::date                  AS data_saida,
    nfm.dat_hor_entrega::date                AS data_entrega,
    nfm.sit_nota_fiscal,

    -- Order origin (from CRM module)
    nfi.pedido                               AS num_pedido,
    nfi.seq_item_pedido,
    cp.dat_emis_pedido::date                 AS data_pedido,
    cp.dat_prazo_entrega::date               AS data_prazo,
    cp.cod_repres,
    cp.ies_sit_pedido                        AS situacao_pedido,

    -- Customer (CNPJ is the primary key in this ERP)
    c.cod_cliente                            AS cliente_cnpj,
    c.nom_cliente                            AS cliente,
    c.nom_reduzido                           AS cliente_reduz,
    c.cod_tip_cli                            AS cod_tipo_cliente,
    cid.den_cidade                           AS cliente_municipio,
    cid.cod_uni_feder                        AS cliente_uf,

    -- Product
    nfi.item                                 AS cod_item,
    nfi.des_item                             AS item_descricao,
    nfi.unid_medida                          AS un,
    i.cod_lin_prod,
    lp.den_estr_linprod                      AS linha_produto,

    -- Quantities & liters
    nfi.qtd_item                             AS qtd,
    COALESCE(pe.val_pes_espec, pe_mtz.val_pes_espec, 0) AS litros_por_un,
    nfi.qtd_item * COALESCE(pe.val_pes_espec, pe_mtz.val_pes_espec, 0) AS litros,

    -- Values
    nfi.preco_unit_liquido                   AS vlr_unit,
    nfi.val_liquido_item                     AS vlr_total,
    nfi.val_merc_item                        AS vlr_mercadoria,
    nfi.val_desc_item                        AS vlr_desconto,
    nfm.val_nota_fiscal                      AS val_nf_total

FROM fat_nf_mestre nfm
JOIN fat_nf_item nfi
  ON nfi.empresa = nfm.empresa
 AND nfi.trans_nota_fiscal = nfm.trans_nota_fiscal
LEFT JOIN nat_operacao no_ ON no_.cod_nat_oper = nfm.natureza_operacao
LEFT JOIN clientes c ON c.cod_cliente = nfm.cliente
LEFT JOIN cidades cid ON cid.cod_cidade = c.cod_cidade
LEFT JOIN item i ON i.cod_empresa = nfi.empresa AND i.cod_item = nfi.item
LEFT JOIN linha_prod lp ON lp.cod_lin_prod = i.cod_lin_prod
LEFT JOIN crm_pedido cp ON cp.cod_empresa = nfi.empresa AND cp.num_pedido = nfi.pedido
LEFT JOIN peso_especifico pe ON pe.cod_empresa = nfi.empresa AND pe.cod_item = nfi.item
LEFT JOIN peso_especifico pe_mtz ON pe_mtz.cod_empresa = '01' AND pe_mtz.cod_item = nfi.item

-- TRIPLE CHECK anti-duplication
WHERE nfm.natureza_operacao IN (1, 11, 13)
  AND nfm.sit_nota_fiscal = 'N'
  AND nfm.cliente NOT IN (SELECT cod_cliente FROM empresa WHERE cod_cliente IS NOT NULL)

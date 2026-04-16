-- =============================================================================
-- 03_fat_pedidos.sql
-- =============================================================================
-- Pedidos de venda -- 1 linha por item de pedido
-- Power BI: Transformar Dados -> fat_pedidos -> Editor Avancado
-- Usar formato M com Odbc.Query (ver fat_vendas como referencia de conexao)
--
-- DATAS CORRETAS vem da tabela crm_audit (log de auditoria DAGDA):
--    DATA PEDIDO   = audit campo AUDITMSG LIKE '%pedido%criado%'
--    DATA CONVERSAO = audit campo IES_TIPO = 'P' (orcamento -> pedido)
--    DATA CORRETA  = COALESCE(data_pedido, data_conversao)
--
--    NAO usar dat_emis_pedido nem dat_emis_repres -- ambos sao sobrescritos
--    em edicoes e nao representam a data real de entrada do pedido.
--
-- FILTROS:
--   (a) ies_tipo = 'P'                  -> somente pedidos (nao orcamentos)
--   (b) ies_suspenso <> 'S'             -> exclui suspensos (processo interno que duplica)
--   (c) cod_cliente NOT IN empresa       -> exclui transferencias intragrupo
--
-- DUAS colunas de litros:
--   litros_pedido = qtd_solicitada x peso   -> Entrada de Pedidos (total pedido)
--   litros_saldo  = qtd_saldo x peso        -> Saldo Carteira (ainda a faturar)
-- =============================================================================

SELECT
    cp.cod_empresa,
    cp.num_pedido,

    -- Data correta de entrada: auditoria de criacao do pedido ou conversao orc->ped
    COALESCE(aud_k.data_pedido, aud_z.data_conversao) AS data_pedido,
    cp.dat_emis_repres::date                 AS dt_emissao,
    cp.dat_prazo_entrega::date               AS data_prazo,
    cp.dat_cancel::date                      AS data_cancel,

    -- cliente
    cp.cod_cliente                           AS cliente_cnpj,
    c.nom_cliente                            AS cliente,
    cid.cod_uni_feder                        AS cliente_uf,

    -- vendedor
    cp.cod_repres,

    -- situacao / bloqueios
    cp.ies_sit_pedido                        AS situacao,
    cp.bloqueio_financeiro,
    cp.bloqueio_comercial,
    cp.bloqueio_logistica,
    cp.bloqueio_fiscal,
    cp.bloqueio_antecipado,
    cp.ies_suspenso,
    CASE
        WHEN cp.dat_cancel IS NOT NULL    THEN 'CANCELADO'
        WHEN cp.ies_suspenso = 'S'        THEN 'SUSPENSO'
        WHEN cp.bloqueio_financeiro = 'S' THEN 'BLOQ_FINANC'
        WHEN cp.bloqueio_comercial  = 'S' THEN 'BLOQ_COMERC'
        WHEN cp.bloqueio_logistica  = 'S' THEN 'BLOQ_LOGIST'
        WHEN cp.bloqueio_fiscal     = 'S' THEN 'BLOQ_FISCAL'
        WHEN cp.bloqueio_antecipado = 'S' THEN 'BLOQ_ANTEC'
        ELSE 'LIBERADO'
    END                                      AS status_pedido,

    -- item
    cpi.num_sequencia                        AS item_seq,
    cpi.cod_item,
    cpi.den_item,
    cpi.cod_unid_med                         AS un,
    i.cod_lin_prod,
    lp.den_estr_linprod                      AS linha_produto,
    fam.den_familia                          AS familia,

    -- quantidades
    cpi.qtd_pecas_solic                      AS qtd_solicitada,
    COALESCE(cpi.qtd_pecas_atend,  0)        AS qtd_atendida,
    COALESCE(cpi.qtd_pecas_cancel, 0)        AS qtd_cancelada,
    (cpi.qtd_pecas_solic
        - COALESCE(cpi.qtd_pecas_atend, 0)
        - COALESCE(cpi.qtd_pecas_cancel, 0)) AS qtd_saldo,

    -- LITROS PEDIDO: total solicitado x peso (= Entrada de Pedidos)
    cpi.qtd_pecas_solic
        * COALESCE(pe.val_pes_espec, pe_mtz.val_pes_espec, 0) AS litros_pedido,

    -- LITROS SALDO: ainda a faturar x peso (= Carteira em Aberto)
    (cpi.qtd_pecas_solic
        - COALESCE(cpi.qtd_pecas_atend, 0)
        - COALESCE(cpi.qtd_pecas_cancel, 0))
        * COALESCE(pe.val_pes_espec, pe_mtz.val_pes_espec, 0) AS litros_saldo,

    -- flag em aberto
    CASE WHEN cp.dat_cancel IS NULL
          AND (cpi.qtd_pecas_solic
               - COALESCE(cpi.qtd_pecas_atend, 0)
               - COALESCE(cpi.qtd_pecas_cancel, 0)) > 0
         THEN 1 ELSE 0 END                   AS em_aberto,

    -- valores
    cpi.pre_unit_liquido                     AS vlr_unit,
    cpi.val_tot_merc                         AS vlr_total,
    cpi.val_liquido                          AS vlr_liquido,
    cpi.val_custo_medio                      AS custo_unit,
    cpi.val_custo_total                      AS custo_total,
    cpi.val_margem                           AS margem_total,
    cpi.pct_margem                           AS margem_pct

FROM crm_pedido cp
JOIN crm_pedido_item cpi
  ON cpi.cod_empresa = cp.cod_empresa
 AND cpi.num_pedido  = cp.num_pedido

LEFT JOIN clientes c
  ON c.cod_cliente = cp.cod_cliente

LEFT JOIN cidades cid
  ON cid.cod_cidade = c.cod_cidade

LEFT JOIN item i
  ON i.cod_empresa = cp.cod_empresa
 AND i.cod_item    = cpi.cod_item

LEFT JOIN (
    SELECT cod_lin_prod, MAX(den_estr_linprod) AS den_estr_linprod
    FROM linha_prod GROUP BY cod_lin_prod
) lp ON lp.cod_lin_prod = i.cod_lin_prod

LEFT JOIN (
    SELECT cod_empresa, cod_familia, MAX(den_familia) AS den_familia
    FROM familia GROUP BY cod_empresa, cod_familia
) fam ON fam.cod_empresa = cp.cod_empresa
     AND fam.cod_familia  = i.cod_familia

-- Litragem: empresa do pedido com fallback MTZ (01)
LEFT JOIN peso_especifico pe
  ON pe.cod_empresa = cp.cod_empresa
 AND pe.cod_item    = cpi.cod_item

LEFT JOIN peso_especifico pe_mtz
  ON pe_mtz.cod_empresa = '01'
 AND pe_mtz.cod_item    = cpi.cod_item

-- DATA PEDIDO: quando o audit registrou 'pedido criado'
LEFT JOIN (
    SELECT
        substring(chave,1,2)                    AS cod_empresa,
        rtrim(ltrim(substring(chave,4,6)))::int  AS num_pedido,
        MIN(datahora)::date                      AS data_pedido
    FROM crm_audit
    WHERE nom_tabela = 'CRM_PEDIDO'
      AND campo      = 'AUDITMSG'
      AND lower(new_val) LIKE '%pedido%criado%'
    GROUP BY substring(chave,1,2), rtrim(ltrim(substring(chave,4,6)))::int
) aud_k ON aud_k.cod_empresa = cp.cod_empresa
       AND aud_k.num_pedido  = cp.num_pedido

-- DATA CONVERSAO: quando ies_tipo virou 'P' (orcamento -> pedido)
LEFT JOIN (
    SELECT
        substring(chave,1,2)                    AS cod_empresa,
        rtrim(ltrim(substring(chave,4,6)))::int  AS num_pedido,
        MIN(datahora)::date                      AS data_conversao
    FROM crm_audit
    WHERE nom_tabela = 'CRM_PEDIDO'
      AND campo      = 'IES_TIPO'
      AND new_val    = 'P'
    GROUP BY substring(chave,1,2), rtrim(ltrim(substring(chave,4,6)))::int
) aud_z ON aud_z.cod_empresa = cp.cod_empresa
       AND aud_z.num_pedido  = cp.num_pedido

WHERE cp.ies_tipo = 'P'                          -- somente pedidos (nao orcamentos)
  AND (cp.ies_suspenso IS NULL
       OR cp.ies_suspenso <> 'S')               -- exclui suspensos (duplicam pedidos internos)
  AND cp.cod_cliente NOT IN (                    -- exclui transferencias intragrupo
      SELECT cod_cliente FROM empresa WHERE cod_cliente IS NOT NULL
  )

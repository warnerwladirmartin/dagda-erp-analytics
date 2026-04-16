-- =============================================================================
-- 06_dim_cliente.sql
-- =============================================================================
-- Dimensao de cliente (cadastro + derivacao de UF)
-- Power BI: Obter Dados -> PostgreSQL -> Avancado -> colar esta query
-- Nome sugerido da query: dim_cliente
--
-- O calculo de STATUS (Ativo/A Inativar/Inativo) e da CURVA ABC vai ser feito
-- em DAX no Power BI (ver dax_measures.dax) para ficar dinamico com o filtro
-- de periodo. Aqui na query so trazemos o cadastro estatico.
-- =============================================================================

SELECT
    c.cod_cliente                  AS cnpj,
    c.nom_cliente                  AS cliente,
    c.nom_reduzido                 AS cliente_reduz,
    c.cod_tip_cli                  AS cod_tipo_cliente,
    c.cod_class                    AS cod_classificacao,
    cid.den_cidade                 AS municipio,
    cid.cod_uni_feder              AS uf,
    c.ies_situacao                 AS situacao_cadastro,
    c.dat_cadastro                 AS data_cadastro,
    c.dat_atualiz                  AS data_atualizacao
FROM clientes c
LEFT JOIN cidades cid
  ON cid.cod_cidade = c.cod_cidade
WHERE c.ies_situacao IN ('S','A')                     -- ativo no cadastro (confirmar)
  AND c.cod_cliente NOT IN (                           -- exclui empresas do grupo
      SELECT cod_cliente FROM empresa WHERE cod_cliente IS NOT NULL
  )

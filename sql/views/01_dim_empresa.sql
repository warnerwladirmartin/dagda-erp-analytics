-- =============================================================================
-- dim_empresa — Company dimension with business classification
-- =============================================================================
-- 22 business units: 1 oil factory, 1 packaging plant, 18 commercial branches,
-- 1 distributor, 1 non-commercial subsidiary.
--
-- The ERP has no native classification for "factory vs branch vs distributor",
-- so we JOIN with a CSV-based lookup table loaded in Power BI.
-- =============================================================================

SELECT
    e.cod_empresa,
    e.den_empresa,
    e.den_reduz,
    e.den_munic         AS municipio,
    e.uni_feder         AS uf,
    e.num_cgc           AS cnpj,
    e.ies_filial,
    e.cod_cliente        AS cliente_espelho  -- each company has a "mirror" customer record for inter-company invoices
FROM empresa e
ORDER BY e.cod_empresa

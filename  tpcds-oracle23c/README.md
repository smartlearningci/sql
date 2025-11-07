# Projeto TPC-DS com Oracle 23c e DuckDB

## 📘 Visão Geral

Este repositório documenta a criação **passo a passo** de um ambiente de demonstração do **TPC-DS Benchmark** sobre **Oracle Database 23c Free**, gerando os dados com o **DuckDB** e orquestrando tudo num **Ubuntu com Docker**.

Ideal para aulas, demonstrações e testes de desempenho em SQL.

---

## 🧩 Estrutura do Projeto

```
📁 tpcds-oracle23c/
├── setup.sh                # Script de instalação completo
├── reload_sf10.sql         # Script para recarregar SF=10
├── demo_queries.sql        # Consultas de demonstração com plano de execução
├── README.md               # Este documento
└── alunos_acesso.md        # Guia para alunos e utilizadores finais
```

---

## ☁️ 1. Instalação da VM no Azure

1. Criar uma **Máquina Virtual Ubuntu 24.04 LTS** (tamanho recomendado: **Standard_B2s**, disco de 64 GB).
2. Atribuir **porta 1521** (Oracle) e **porta 22** (SSH) abertas no grupo de segurança.
3. Aceder via SSH:
   ```bash
   ssh azureuser@<ip_publico>
   ```
4. Clonar o repositório:
   ```bash
   git clone https://github.com/<teu-repo>/tpcds-oracle23c.git
   cd tpcds-oracle23c
   ```

---

## 🐋 2. Instalação do Oracle 23c Free e DuckDB

Executar o script automático:

```bash
chmod +x setup.sh
./setup.sh
```

O script faz:
- Instalação do Docker e dependências
- Download e execução do Oracle 23c Free
- Criação de utilizador `tpcds`
- Instalação do Python e DuckDB
- Geração do TPC-DS SF=1 e exportação dos `.dat`
- Criação das tabelas externas e carga no Oracle

---

## 🗃️ 3. Estrutura de Dados

As tabelas principais criadas são:
- `DATE_DIM`
- `CUSTOMER`
- `ITEM`
- `STORE_SALES`
- `STORE`
- `CATALOG_SALES`
- `WEB_SALES`

Os dados ficam localizados em:
```
/opt/oradata/tpcds_data/
```

---

## 🧮 4. Consultas de Demonstração

Para testar o desempenho, utilizar:
```sql
@demo_queries.sql
```

Inclui:
- `JOIN` entre `store_sales`, `date_dim` e `item`
- `GROUP BY` e `ORDER BY`
- Exibição do plano com `DBMS_XPLAN.DISPLAY_CURSOR(FORMAT=>'ALLSTATS LAST')`

---

## 🔁 5. Recarregar com Maior Volume (SF=10)

Para aumentar o volume:
1. Ativar o ambiente DuckDB:
   ```bash
   source ~/venvs/duck/bin/activate
   python - << 'PY'
   import duckdb, os
   outdir = "/opt/oradata/tpcds_data"
   os.makedirs(outdir, exist_ok=True)
   duckdb.sql("INSTALL tpcds;")
   duckdb.sql("LOAD tpcds;")
   duckdb.sql("CALL dsdgen(sf=10, schema='main', overwrite=true);")
   for t in ['store_sales','catalog_sales','web_sales']:
       duckdb.sql(f"COPY {t} TO '{outdir}/{t}.dat' (FORMAT CSV, DELIMITER '|', HEADER false, NULL '');")
   PY
   ```
2. Atualizar permissões:
   ```bash
   sudo chown -R 54321:54321 /opt/oradata/tpcds_data
   sudo chmod -R 775 /opt/oradata/tpcds_data
   ```
3. Recarregar no Oracle:
   ```bash
   docker exec -i oracle23c sqlplus tpcds/TPCDS_123@//localhost/FREEPDB1 @reload_sf10.sql
   ```

---

## 🧑‍🏫 6. Acesso para Alunos / DBeaver

Ver o ficheiro `alunos_acesso.md` para configuração de ligação, screenshots e exemplos.

---

## 🧠 Notas Técnicas

- **Oracle Container Name:** `oracle23c`
- **Listener:** `FREEPDB1`
- **Utilizador:** `tpcds`
- **Password:** `TPCDS_123`
- **Porta:** `1521`
- **Extensão DuckDB:** `tpcds`
- **Versão recomendada de Docker:** `24+`
- **RAM mínima:** `4 GB` (8 GB recomendável para SF>1)

---

## 🧾 Créditos

- Baseado em TPC-DS Benchmark (Transaction Processing Performance Council)
- Oracle Database Free 23c — Oracle Corporation
- DuckDB — DuckDB Labs

---

## 🪶 Autor

Preparado por [SMART LEARNING / EDUCAR+] para uso formativo no contexto das unidades de DevOps e Data Analytics (2025).

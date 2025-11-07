# Guia de Acesso para Alunos — Oracle 23c + TPC-DS

## 🎯 Objetivo

Este guia explica como aceder à base de dados **TPC-DS** no **Oracle 23c Free** configurado na VM Azure.

---

## 🧩 1. Parâmetros de Ligação

| Parâmetro | Valor |
|------------|--------|
| **Host** | `<IP público da VM>` |
| **Porta** | `1521` |
| **Serviço (Service name)** | `FREEPDB1` |
| **Utilizador** | `tpcds` |
| **Palavra-passe** | `TPCDS_123` |

---

## 🧰 2. Acesso via DBeaver

1. Abrir o **DBeaver** → “Nova ligação”.
2. Escolher **Oracle**.
3. Inserir:
   ```
   Host: <ip_publico>
   Porta: 1521
   Serviço: FREEPDB1
   Utilizador: tpcds
   Palavra-passe: TPCDS_123
   ```
4. Testar ligação → “OK”.

---

## 🧑‍💻 3. Acesso via SQL*Plus (opcional)

```bash
docker exec -it oracle23c sqlplus tpcds/TPCDS_123@//localhost/FREEPDB1
```

---

## 📊 4. Consultas de Demonstração

```sql
SELECT COUNT(*) FROM store_sales;
SELECT s_store_name, SUM(ss_sales_price) AS total
FROM store_sales JOIN store USING (s_store_sk)
GROUP BY s_store_name ORDER BY total DESC FETCH FIRST 10 ROWS ONLY;
```

---

## ⚙️ 5. Ferramentas Recomendadas

- **DBeaver CE** (interface gráfica)
- **SQL Developer** (alternativa da Oracle)
- **DuckDB CLI** para geração de novos datasets

---

## 🧠 Dica

Se ocorrer erro “cannot fetch last explain plan from PLAN_TABLE”, criar manualmente:
```sql
@?/rdbms/admin/utlxplan.sql
```

Isto cria a tabela `PLAN_TABLE` no esquema atual para visualização de planos de execução.

---

© 2025 SMART LEARNING / EDUCAR+

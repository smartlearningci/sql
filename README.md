# 🧩 Projeto TPC-DS Completo no Oracle 23c Free (Docker)

Este projeto cria e configura uma base de dados **Oracle 23c Free** em **Docker**, gera automaticamente os **dados TPC-DS completos (24 tabelas)** com **DuckDB**, e carrega tudo no Oracle em formato relacional completo (CTAS com tipos corretos).

Inclui **duas formas de execução**:
1. **Modo automático (script único)** — `tpcds_oracle_full.sh` faz tudo de ponta a ponta.  
2. **Modo manual (passo a passo)** — comandos detalhados para quem prefere executar e inspecionar cada fase.

---

## 📘 Índice

1. [Descrição geral](#descrição-geral)  
2. [Requisitos mínimos](#requisitos-mínimos)  
3. [Criação e preparação da VM](#criação-e-preparação-da-vm)  
4. [Opção 1 – Execução automática (script único)](#opção-1--execução-automática-script-único)  
5. [Opção 2 – Execução manual passo a passo](#opção-2--execução-manual-passo-a-passo)  
6. [Validação e testes](#validação-e-testes)  
7. [Escalar o volume de dados (Scale Factor)](#escalar-o-volume-de-dados-scale-factor)  
8. [Gestão dos ficheiros `.dat`](#gestão-dos-ficheiros-dat)  
9. [Estrutura final do repositório](#estrutura-final-do-repositório)  
10. [Resolução de problemas](#resolução-de-problemas)  
11. [Licença e créditos](#licença-e-créditos)

---

## 🧠 Descrição geral

O **TPC-DS** é um benchmark de referência para data warehouses e sistemas de análise.  
Este projeto automatiza:
- Instalação do Oracle 23c Free via Docker
- Criação do utilizador e diretório de dados
- Geração dos ficheiros `.dat` via DuckDB
- Criação de tabelas externas planas e **CTAS completas (24 tabelas)** com tipos corretos
- Índices essenciais e recolha de estatísticas
- Queries de validação

---

## 🧩 Requisitos mínimos

| Recurso | Mínimo | Recomendado |
|----------|---------|-------------|
| SO | Ubuntu Server 22.04 LTS | 24.04 LTS |
| CPU | 2 vCPUs | 4 vCPUs |
| RAM | 8 GB | 12 GB |
| Disco | 25 GB | 50 GB |
| Internet | Necessária | Necessária |

---

## ☁️ Criação e preparação da VM

### 1️⃣ Criar a VM no Azure (exemplo)
1. VM **Ubuntu Server 22.04 LTS**.  
2. Abrir as portas: `22` (SSH), `1521` (Oracle), `5500` (Oracle EM, opcional).  
3. Ligar por SSH:
   ```bash
   ssh azureuser@<IP_da_VM>
   ```

### 2️⃣ Atualizar o sistema e instalar dependências
```bash
sudo apt update && sudo apt -y upgrade
sudo apt -y install git curl wget unzip htop net-tools
sudo mkdir -p /opt/oradata && sudo chmod -R 777 /opt/oradata
```

---

## ⚙️ Opção 1 – Execução automática (script único)

A forma **mais rápida**. O script faz tudo: Oracle, DuckDB, TPC-DS, CTAS, índices e stats.

### Passos
```bash
git clone https://github.com/<teu_utilizador>/<teu_repo>.git
cd <teu_repo>
chmod +x tpcds_oracle_full.sh

# (opcional) ajustar variáveis
export SF=1                # Fator de escala (1=rápido; 10/50/100=mais dados)
export ORACLE_PWD=SenhaForte_123
export TPCDS_USER=tpcds
export TPCDS_PWD=TPCDS_123

# correr
./tpcds_oracle_full.sh
```

O script:
- Cria o container `gvenzl/oracle-free:23.5`
- Cria `TPCDS_DIR` e o utilizador `tpcds`
- Gera **24 .dat** via DuckDB
- Cria **externas planas** + **CTAS completas (24 tabelas)**
- Cria PKs essenciais e recolhe estatísticas
- Executa validações

---

## 🪜 Opção 2 – Execução manual passo a passo

### 1) Instalar Docker e Python
```bash
sudo apt -y install docker.io python3 python3-venv python3-pip
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
# sai e volta a entrar na sessão SSH

python3 -m venv $HOME/venvs/duck
source $HOME/venvs/duck/bin/activate
pip install --upgrade pip duckdb
```

### 2) Subir o Oracle 23c Free
```bash
docker run -d --name oracle23c \
  -p 1521:1521 -p 5500:5500 \
  -e ORACLE_PASSWORD=SenhaForte_123 \
  -e ORACLE_CHARACTERSET=AL32UTF8 \
  -v /opt/oradata:/opt/oracle/oradata \
  gvenzl/oracle-free:23.5

until [ "$(docker inspect -f '{{.State.Health.Status}}' oracle23c)" = "healthy" ]; do
  sleep 5; echo -n "."
done
```

### 3) Criar utilizador e diretório
```bash
docker exec -i oracle23c sqlplus system/SenhaForte_123@//localhost/FREEPDB1 <<'SQL'
CREATE USER tpcds IDENTIFIED BY TPCDS_123 QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE, CREATE TABLE TO tpcds;
CREATE OR REPLACE DIRECTORY TPCDS_DIR AS '/opt/oracle/oradata/tpcds_data';
GRANT READ, WRITE ON DIRECTORY TPCDS_DIR TO tpcds;
EXIT
SQL
```

### 4) Gerar ficheiros TPC-DS
```bash
sudo mkdir -p /opt/oradata/tpcds_data && sudo chmod -R 777 /opt/oradata/tpcds_data
source $HOME/venvs/duck/bin/activate
python3 - <<'PY'
import duckdb, os, pathlib
outdir = pathlib.Path("/opt/oradata/tpcds_data"); outdir.mkdir(parents=True, exist_ok=True)
duckdb.sql("INSTALL tpcds;"); duckdb.sql("LOAD tpcds;")
duckdb.sql("CALL dsdgen(sf=1, schema='main', overwrite=true);")
tables = [
  "call_center","catalog_page","catalog_returns","catalog_sales","customer",
  "customer_address","customer_demographics","date_dim","household_demographics",
  "income_band","inventory","item","promotion","reason","ship_mode","store",
  "store_returns","store_sales","time_dim","warehouse","web_page","web_returns",
  "web_sales","web_site"
]
for t in tables:
    duckdb.sql(f"COPY {t} TO '{outdir}/{t}.dat' (FORMAT CSV, DELIMITER '|', HEADER false, NULL '');")
print("Exportados", len(tables), "ficheiros .dat")
PY
```

### 5) Criar tabelas externas planas e CTAS completas
> Recomenda-se usar o **script automático** para gerar as CTAS completas de 24 tabelas.  
> Em alternativa, podes adaptar DDL conforme as tuas necessidades.

---

## ✅ Validação e testes

Ligação (SQL Developer / DBeaver / DataGrip):

| Campo | Valor |
|------|-------|
| Host | IP público da VM |
| Porta | 1521 |
| Service | FREEPDB1 |
| User | tpcds |
| Pass | TPCDS_123 |

Queries rápidas:
```sql
SELECT COUNT(*) FROM store_sales;
SELECT COUNT(*) FROM web_sales;
SELECT COUNT(*) FROM catalog_sales;

SELECT s.s_store_name, SUM(ss.ss_sales_price) AS total
FROM store_sales ss
JOIN store s ON s.s_store_sk = ss.ss_store_sk
GROUP BY s.s_store_name
ORDER BY total DESC
FETCH FIRST 10 ROWS ONLY;
```

---

## 📈 Escalar o volume de dados (Scale Factor)
```bash
export SF=10
./tpcds_oracle_full.sh
```

---

## 📦 Gestão dos ficheiros `.dat`

- São gerados automaticamente em `/opt/oradata/tpcds_data/`  
- **Não** devem ser colocados no GitHub (tamanho elevado)  
- Para partilhar, compacta e publica noutro serviço:
  ```bash
  sudo tar czvf tpcds_data_sf1.tar.gz /opt/oradata/tpcds_data
  ```

---

## 📁 Estrutura final do repositório
```
.
├── README.md
├── tpcds_oracle_full.sh
├── .env.example
└── docs/   (opcional)
```

---

## 🧰 Resolução de problemas

| Erro | Causa | Solução |
|------|------|---------|
| ORA-01031 | falta de privilégios | `GRANT CREATE TABLE TO tpcds;` |
| ORA-29913 | permissões/ficheiro inválido | verificar `/opt/oradata/tpcds_data` |
| DuckDB “Table not found” | dsdgen não correu | repetir geração (Opção 1 ou passo 4) |
| Oracle “unhealthy” | recursos insuficientes | aumentar RAM/CPU ou reiniciar VM |

---

## 🧾 Licença e créditos
Licença sugerida: **MIT**  
Autor: *(o teu nome/organização)*  
Ano: 2025

# REQUISITOS

1) Ter o postgresql-client instalado;
2) Na primeira execução do scipt, adicione os dados para gerar o env corretamente usando a opção 6 do menu (Atualizar configurações);

## INSTALANDO O POSTGRESQL-CLIENT
Para instalar o cliente do PostgreSQL 15 usando `apt-get`, você precisará adicionar o repositório apropriado à sua lista de fontes, já que os repositórios padrão do sistema podem não incluir a versão desejada. Siga os passos abaixo:

### Passos para instalar o cliente PostgreSQL 15:

1. **Adicione o repositório oficial do PostgreSQL**:

```bash
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
```

2. **Importe a chave GPG do repositório**:
```bash
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
```

3. **Atualize os pacotes do sistema**:
```bash
sudo apt-get update
```

4. **Instale o cliente PostgreSQL 15**:
```bash
sudo apt-get install postgresql-client-15
```

### Verificar a instalação:

Para confirmar que o cliente PostgreSQL 15 foi instalado corretamente, use o comando:

```bash
psql --version
```

A saída deve indicar a versão 15, como:

```bash
psql (PostgreSQL) 15.x
```

# BAIXANDO E EXECUTANDO O SCRIPT

```bash
bash <(curl -sSL https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/setup_backup.sh)
```
# Routine Backup BD
Rotina de backup de banco de dados (postgres slq) via servidor com opção de restauração

# Necessário Verificar Antes

## Verificar pg_dump
pg_dump --version

## Verificar cron
crontab -l
systemctl status cron

## Verificar curl
curl --version

# Setup
## Configurando o Diretório de Backups Usando o Usuário root

```shell
# Criar o Diretório de Backups
sudo mkdir -p /var/backups/postgres
# Alterar a Propriedade do Diretório para root:root
sudo chown root:root /var/backups/postgres 
```

## Configurando a Autenticação Automática com .pgpass

Criar o Arquivo .pgpass em:

```shell
nano /root/.pgpass
```

No arquivo, adicione:

```shell
touch /root/.pgpass
chmod 600 /root/.pgpass
# Altere os dados, ip, usuario e senha
localhost:5432:postgres:seu_usuario:sua_senha
```

## Criando o Script de Backup

Criar o Script:

```shell
nano /usr/local/bin/backup_postgres.sh
```

Adicionar o Conteúdo ao Script:

```shell
#!/bin/bash

########################################
# Configurações
########################################

# Data e Hora Atual
DATA=$(date +%Y-%m-%d)
HORA=$(date +%H:%M:%S)

# Diretório de Backup
DIRETORIO_BACKUP="/var/backups/postgres"

# Nome do Banco de Dados
BANCO="postgres"  # Substitua se necessário

# Usuário do PostgreSQL
USUARIO="postgres"  # Substitua pelo usuário do PostgreSQL

# Host e Porta do PostgreSQL
HOST="154.38.173.92"
PORTA="5432"

# Período de Retenção em Dias
RETENCAO_DIAS=30  # Variável configurável

# Webhook URL
WEBHOOK_URL="https://whk.supercaso.com.br/webhook/routine-backup-bd"

########################################
# Funções
########################################

# Função para enviar webhook
enviar_webhook() {
  local payload="$1"
  curl -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL"
}

########################################
# Processo de Backup
########################################

# Nome do Arquivo de Backup
ARQUIVO_BACKUP="${BANCO}_backup_$(date +%Y%m%d%H%M%S).backup"

# Caminho Completo do Backup
CAMINHO_BACKUP="${DIRETORIO_BACKUP}/${ARQUIVO_BACKUP}"

# Realiza o Backup
pg_dump -U "$USUARIO" -h "$HOST" -p "$PORTA" -F c -b -v -f "$CAMINHO_BACKUP" "$BANCO"
STATUS_BACKUP=$?

# Verifica se o Backup foi Bem-Sucedido
if [ $STATUS_BACKUP -eq 0 ]; then
  STATUS="OK"
  NOTES="Backup executado conforme cron job configurado. Nenhum erro reportado durante o processo."
  BACKUP_SIZE=$(du -h "$CAMINHO_BACKUP" | cut -f1)
else
  STATUS="ERRO"
  NOTES="Falha ao executar o backup. Verifique os logs para mais detalhes."
  BACKUP_SIZE="0B"
fi

########################################
# Gerenciamento de Retenção
########################################

# Lista de Backups Antigos que Excedem o Período de Retenção
BACKUPS_ANTIGOS=$(find "$DIRETORIO_BACKUP" -type f -name "${BANCO}_backup_*.backup" -mtime +$RETENCAO_DIAS)

DELETED_BACKUPS_JSON="[]"

if [ -n "$BACKUPS_ANTIGOS" ]; then
  DELETED_BACKUPS=()
  for arquivo in $BACKUPS_ANTIGOS; do
    nome_backup=$(basename "$arquivo")
    # Remove o Arquivo
    rm -f "$arquivo"
    # Adiciona Detalhes ao JSON
    DELETED_BACKUPS+=("{\"backup_name\": \"$nome_backup\", \"deletion_reason\": \"Prazo de retenção expirado\"}")
  done
  # Converte o Array para JSON
  DELETED_BACKUPS_JSON=$(IFS=, ; echo "[${DELETED_BACKUPS[*]}]")
fi

########################################
# Enviar Notificação via Webhook
########################################

# Preparar o Payload JSON
PAYLOAD=$(cat <<EOF
{
  "action": "Backup realizado com sucesso",
  "date": "$(date '+%d/%m/%Y %H:%M:%S')",
  "database_name": "$BANCO",
  "backup_file": "$(basename "$ARQUIVO_BACKUP")",
  "backup_size": "$BACKUP_SIZE",
  "retention_days": $RETENCAO_DIAS,
  "deleted_backup": $DELETED_BACKUPS_JSON,
  "status": "$STATUS",
  "notes": "$NOTES"
}
EOF
)

# Enviar o Webhook
enviar_webhook "$PAYLOAD"

# Log (Opcional)
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Backup $STATUS: $(basename "$ARQUIVO_BACKUP"), Size: $BACKUP_SIZE" >> /var/log/backup_postgres.log
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Backups antigos removidos: $DELETED_BACKUPS_JSON" >> /var/log/backup_postgres.log
```

Explicação do Script:

- Variáveis de Configuração: Define os parâmetros necessários, incluindo diretório de backup, nome do banco de dados, usuário, host, porta, período de retenção e URL do webhook.
- Função enviar_webhook: Envia uma requisição POST com o payload JSON para a URL do webhook especificada.
- Processo de Backup: Executa o pg_dump para criar o backup. Verifica se o comando foi bem-sucedido e captura o tamanho do backup.
- Gerenciamento de Retenção: Encontra e remove backups que excedem o período de retenção definido.
- Notificação via Webhook: Prepara e envia um payload JSON detalhando o backup realizado e quaisquer backups deletados.
- Logs: Adiciona entradas nos logs para monitoramento.

Tornar o Script Executável:

```shell
chmod +x /usr/local/bin/backup_postgres.sh
```

## Configurando o Cron Job para Executar o Backup Diariamente às 00:00

Editar o Crontab do Usuário root:

```shell
crontab -e
```
Adicionar a Linha do Cron:

```shell
0 0 * * * /usr/local/bin/backup_postgres.sh >> /var/log/backup_postgres_cron.log 2>&1
```

## Testando o Script de Backup Manualmente

Executar o Script de Backup:

```shell
/usr/local/bin/backup_postgres.sh
```

Verificar a Criação do Arquivo de Backup:

```shell
ls -lh /var/backups/postgres/
```
Você deve ver um arquivo de backup recente, por exemplo:

```shell
-rw------- 1 root root 15M Dez  2 00:00 postgres_backup_20241202000000.backup
```

Verificar os Logs:

```shell
cat /var/log/backup_postgres_cron.log
```

Exemplo de Entrada de Log:

```shell
[2024-12-02 00:00:01] Backup OK: postgres_backup_20241202000000.backup, Size: 15M
[2024-12-02 00:00:01] Backups antigos removidos: []
```

# Criando o Script de Restauração

Criar o Script restore_postgres.sh: 

```shell
nano /usr/local/bin/restore_postgres.sh
```

Adicionar o Conteúdo ao Script:

```shell
#!/bin/bash

########################################
# Configurações
########################################

# Diretório de Backup
DIRETORIO_BACKUP="/var/backups/postgres"

# Nome do Banco de Dados
BANCO="postgres"  # Substitua se necessário

# Usuário do PostgreSQL
USUARIO="seu_usuario"  # Substitua pelo usuário do PostgreSQL

# Host e Porta do PostgreSQL
HOST="localhost"
PORTA="5432"

########################################
# Funções
########################################

# Função para listar backups
listar_backups() {
  echo "Listagem de Backups Disponíveis para o Banco '$BANCO':"
  echo "-----------------------------------------------------"
  mapfile -t BACKUP_LIST < <(ls -1t "$DIRETORIO_BACKUP/${BANCO}_backup_"*.backup 2>/dev/null)
  
  if [ ${#BACKUP_LIST[@]} -eq 0 ]; then
    echo "Nenhum backup encontrado no diretório $DIRETORIO_BACKUP."
    exit 1
  fi

  for i in "${!BACKUP_LIST[@]}"; do
    echo "$((i+1))). $(basename "${BACKUP_LIST[$i]}") - $(du -h "${BACKUP_LIST[$i]}" | cut -f1)"
  done
}

# Função para selecionar o backup
selecionar_backup() {
  echo ""
  read -p "Digite o número do backup que deseja restaurar: " SELECAO

  if ! [[ "$SELECAO" =~ ^[0-9]+$ ]]; then
    echo "Entrada inválida. Por favor, insira um número."
    exit 1
  fi

  if [ "$SELECAO" -lt 1 ] || [ "$SELECAO" -gt "${#BACKUP_LIST[@]}" ]; then
    echo "Número fora do intervalo. Por favor, selecione um número válido."
    exit 1
  fi

  BACKUP_SELECIONADO="${BACKUP_LIST[$((SELECAO-1))]}"
  echo "Backup Selecionado: $(basename "$BACKUP_SELECIONADO")"
}

# Função para confirmar a restauração
confirmar_restauracao() {
  echo ""
  read -p "Tem certeza que deseja restaurar este backup? Isso sobrescreverá o banco de dados atual. (yes/no): " CONFIRMA

  case "$CONFIRMA" in
    yes|Yes|YES)
      ;;
    *)
      echo "Restauração cancelada pelo usuário."
      exit 1
      ;;
  esac
}

# Função para realizar a restauração
restaurar_backup() {
  echo "Iniciando a restauração do backup..."
  pg_restore -U "$USUARIO" -h "$HOST" -p "$PORTA" -d "$BANCO" -c "$BACKUP_SELECIONADO"
  STATUS_RESTORE=$?

  if [ $STATUS_RESTORE -eq 0 ]; then
    echo "Restauração concluída com sucesso."
  else
    echo "Falha na restauração do backup." >&2
    exit 1
  fi
}

########################################
# Execução do Script
########################################

listar_backups
selecionar_backup
confirmar_restauracao
restaurar_backup
```
Tornar o Script Executável:

```shell
chmod +x /usr/local/bin/restore_postgres.sh
```

Testar o Script de Restauração Manualmente:

```shell
/usr/local/bin/restore_postgres.sh
```



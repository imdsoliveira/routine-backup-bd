#!/bin/bash

# restore_postgres.sh
# Script de Restauração Automática do PostgreSQL

set -euo pipefail

# Carregar variáveis do .env
ENV_FILE="/root/.backup_postgres.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo_error "Arquivo de configuração $ENV_FILE não encontrado."
    exit 1
fi

# Funções para exibir mensagens coloridas
function echo_info() {
    echo -e "\e[34m[INFO]\e[0m $1" >&2
}

function echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1" >&2
}

function echo_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1" >&2
}

function echo_error() {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
}

# Função para enviar webhook
function send_webhook() {
    local payload="$1"
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL"
}

# Função para identificar o container PostgreSQL dinamicamente
function find_postgres_container() {
    # Encontrar todos os containers que usam a imagem 'postgres'
    local CONTAINERS=$(docker ps --filter "ancestor=postgres" --format "{{.Names}}")
    if [ -z "$CONTAINERS" ]; then
        echo_error "Nenhum container PostgreSQL encontrado com a imagem 'postgres'."
        exit 1
    elif [ $(echo "$CONTAINERS" | wc -l) -eq 1 ]; then
        echo "$CONTAINERS"
    else
        echo_info "Múltiplos containers PostgreSQL encontrados:"
        echo "$CONTAINERS"
        read -p "Por favor, insira o nome do container PostgreSQL que deseja usar para restauração: " SELECTED_CONTAINER
        if ! echo "$CONTAINERS" | grep -qw "$SELECTED_CONTAINER"; then
            echo_error "Nome do container inválido."
            exit 1
        fi
        echo "$SELECTED_CONTAINER"
    fi
}

# Atualizar dinamicamente o nome do container
CONTAINER_NAME_DYNAMIC=$(find_postgres_container)
if [ -n "$CONTAINER_NAME_DYNAMIC" ]; then
    CONTAINER_NAME="$CONTAINER_NAME_DYNAMIC"
else
    echo_error "Não foi possível identificar o container PostgreSQL."
    exit 1
fi

# Garantir criação do diretório de logs
mkdir -p "$(dirname "$LOG_FILE")" || true
touch "$LOG_FILE" || true
chmod 644 "$LOG_FILE" || true

# Log da Restauração
echo_info "Iniciando processo de restauração..." | tee -a "$LOG_FILE"

# Listar arquivos de backup disponíveis
echo_info "Listando backups disponíveis..." | tee -a "$LOG_FILE"
mapfile -t BACKUPS < <(ls -1 "$BACKUP_DIR" | grep -E "postgres_backup_.*\.backup$" || true)

if [ ${#BACKUPS[@]} -eq 0 ]; then
    echo_error "Nenhum backup encontrado em $BACKUP_DIR" | tee -a "$LOG_FILE"
    ls -la "$BACKUP_DIR" | tee -a "$LOG_FILE" # Debug
    exit 1
fi

echo_info "Backups disponíveis:" | tee -a "$LOG_FILE"
for i in "${!BACKUPS[@]}"; do
    echo "$((i+1))). ${BACKUPS[$i]}"
done | tee -a "$LOG_FILE"

# Selecionar Backup
read -p "Digite o número do backup que deseja restaurar: " SELECTION

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]]; then
    echo_error "Entrada inválida. Por favor, insira um número." | tee -a "$LOG_FILE"
    exit 1
fi

if [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#BACKUPS[@]}" ]; then
    echo_error "Número fora do intervalo. Por favor, selecione um número válido." | tee -a "$LOG_FILE"
    exit 1
fi

SELECTED_BACKUP="${BACKUPS[$((SELECTION-1))]}"
BACKUP_PATH="${BACKUP_DIR}/${SELECTED_BACKUP}"
echo_info "Backup Selecionado: $SELECTED_BACKUP" | tee -a "$LOG_FILE"

# Confirmar Restauração
read -p "Tem certeza que deseja restaurar este backup? Isso sobrescreverá todos os bancos de dados atuais. (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" && "$CONFIRM" != "Yes" && "$CONFIRM" != "YES" ]]; then
    echo_info "Restauração cancelada pelo usuário." | tee -a "$LOG_FILE"
    exit 0
fi

# Transferir o Backup para o Container (se necessário)
echo_info "Transferindo o backup para o container..." | tee -a "$LOG_FILE"
docker cp "$BACKUP_PATH" "$CONTAINER_NAME":/tmp/"$SELECTED_BACKUP"

# Realizar Restauração com pg_restore
echo_info "Realizando restauração completa de todos os bancos de dados..." | tee -a "$LOG_FILE"
docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" pg_restore -U "$PG_USER" -d postgres -v "/tmp/$SELECTED_BACKUP"

# Remover o arquivo de backup do container
docker exec "$CONTAINER_NAME" rm -f "/tmp/$SELECTED_BACKUP"

# Verificar se a Restauração foi Bem-Sucedida
STATUS_RESTORE=$?

if [ $STATUS_RESTORE -eq 0 ]; then
    STATUS="OK"
    NOTES="Restauração executada com sucesso."
    echo_success "Restauração concluída com sucesso: $SELECTED_BACKUP" | tee -a "$LOG_FILE"
else
    STATUS="ERRO"
    NOTES="Falha ao executar a restauração. Verifique os logs para mais detalhes."
    echo_error "Restauração falhou: $SELECTED_BACKUP" | tee -a "$LOG_FILE"
fi

# Preparar o Payload JSON
PAYLOAD=$(cat <<EOF_JSON
{
    "action": "Restauração realizada",
    "date": "$(date '+%d/%m/%Y %H:%M:%S')",
    "database_name": "ALL",
    "backup_file": "$SELECTED_BACKUP",
    "status": "$STATUS",
    "notes": "$NOTES"
}
EOF_JSON
)

# Enviar o Webhook
send_webhook "$PAYLOAD"

# Log da Restauração
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Restauração $STATUS: $SELECTED_BACKUP" >> "$LOG_FILE"

#!/bin/bash

# backup_postgres.sh
# Script de Backup Automático do PostgreSQL

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
        read -p "Por favor, insira o nome do container PostgreSQL que deseja usar para backup: " SELECTED_CONTAINER
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

# Garantir criação do diretório de logs e backup
mkdir -p "$(dirname "$LOG_FILE")" || true
mkdir -p "$BACKUP_DIR" || true
touch "$LOG_FILE" || true
chmod 644 "$LOG_FILE" || true

# Log do Backup
echo_info "Iniciando processo de backup..." | tee -a "$LOG_FILE"

# Nome do Arquivo de Backup
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_FILENAME="postgres_backup_${TIMESTAMP}.backup"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILENAME}"

# Realizar Backup Completo com pg_dumpall
echo_info "Realizando backup completo de todos os bancos de dados..." | tee -a "$LOG_FILE"
docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" pg_dumpall -U "$PG_USER" -F c -b -v -f "/tmp/$BACKUP_FILENAME"

# Transferir o Backup do Container para o Host
echo_info "Transferindo o backup do container para o host..." | tee -a "$LOG_FILE"
docker cp "$CONTAINER_NAME":/tmp/"$BACKUP_FILENAME" "$BACKUP_PATH"

# Remover o arquivo de backup do container
docker exec "$CONTAINER_NAME" rm -f "/tmp/$BACKUP_FILENAME"

# Verificar se o Backup foi Bem-Sucedido
if [ -f "$BACKUP_PATH" ]; then
    BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
    BACKUP_INFO="{ \"database\": \"ALL\", \"filename\": \"$(basename "$BACKUP_PATH")\", \"status\": \"success\", \"size\": \"$BACKUP_SIZE\" }"
    echo_success "Backup concluído com sucesso: $(basename "$BACKUP_PATH") (Tamanho: $BACKUP_SIZE)" | tee -a "$LOG_FILE"
else
    BACKUP_INFO="{ \"database\": \"ALL\", \"filename\": \"$(basename "$BACKUP_PATH")\", \"status\": \"failure\", \"size\": \"0\" }"
    echo_error "Backup falhou: $(basename "$BACKUP_PATH")" | tee -a "$LOG_FILE"
    exit 1
fi

# Enviar notificação via webhook
send_webhook "$BACKUP_INFO"

# Gerenciamento de Retenção
echo_info "Verificando backups antigos que excedem $RETENTION_DAYS dias..." | tee -a "$LOG_FILE"
find "$BACKUP_DIR" -type f -name "postgres_backup_*.backup" -mtime +$RETENTION_DAYS -exec rm -f {} \;
echo_success "Backups antigos removidos." | tee -a "$LOG_FILE"

# Adicionar timestamp ao arquivo de log
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Fim do processo de backup" >> "$LOG_FILE"

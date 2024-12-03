#!/bin/bash

# =============================================================================
# PostgreSQL Backup Manager para Docker
# Versão: 2.0.0
# Autor: System Administrator
# Data: 2024
# =============================================================================
# Descrição: Sistema completo para backup e restauração de bancos PostgreSQL
# rodando em containers Docker, com suporte a:
# - Múltiplos tipos de backup e extensões
# - Compressão automática
# - Verificação de integridade
# - Notificações via webhook
# - Rotação de logs
# - Retenção configurável
# =============================================================================

set -e
set -u
set -o pipefail

# Configurações Globais
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="/root/.backup_postgres.env"
readonly LOG_FILE="/var/log/backup_postgres.log"
readonly MAX_LOG_SIZE=$((50 * 1024 * 1024)) # 50MB
readonly BACKUP_DIR="/var/backups/postgres"

# Garantir criação do diretório de logs
mkdir -p "$(dirname "$LOG_FILE")" || true
touch "$LOG_FILE" || true
chmod 644 "$LOG_FILE" || true

# Funções de Utilidade
function echo_info() { echo -e "\e[34m[INFO]\e[0m $1" | tee -a "$LOG_FILE"; sleep 1; }
function echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1" | tee -a "$LOG_FILE"; sleep 1; }
function echo_warning() { echo -e "\e[33m[WARNING]\e[0m $1" | tee -a "$LOG_FILE"; sleep 1; }
function echo_error() { echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOG_FILE"; sleep 1; }
function command_exists() { command -v "$1" >/dev/null 2>&1; }
function valid_url() { [[ "$1" =~ ^https?://.+ ]]; }

# Função para rotação de logs
function rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null)" -gt "$MAX_LOG_SIZE" ]; then
        local backup_log="${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        mv "$LOG_FILE" "$backup_log"
        gzip "$backup_log"
        echo "=== Log rotacionado em $(date) ===" > "$LOG_FILE"
    fi
}

# Função para carregar variáveis do arquivo .env
function load_env() {
    if [ -f "$ENV_FILE" ]; then
        echo_info "Configurações existentes encontradas:"
        cat "$ENV_FILE"
        echo ""
        read -p "Deseja usar estas configurações? (yes/no): " USE_EXISTING
        if [[ "$USE_EXISTING" =~ ^(yes|Yes|YES)$ ]]; then
            source "$ENV_FILE"
            return 0
        fi
    fi
    return 1
}

# Função para salvar variáveis no arquivo .env
function save_env() {
    cat > "$ENV_FILE" <<EOF
PG_USER="$PG_USER"
PG_PASSWORD="$PG_PASSWORD"
RETENTION_DAYS="$RETENTION_DAYS"
WEBHOOK_URL="$WEBHOOK_URL"
BACKUP_OPTION="$BACKUP_OPTION"
CONTAINER_NAME="$CONTAINER_NAME"
BACKUP_DIR="$BACKUP_DIR"
EOF
    chmod 600 "$ENV_FILE"
    echo_success "Configurações salvas em $ENV_FILE"
}

# Função para verificar montagem do volume
function check_volume_mount() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
    fi

    if ! docker inspect "$CONTAINER_NAME" --format '{{ range .Mounts }}{{ if eq .Destination "'$BACKUP_DIR'" }}{{ .Source }}{{ end }}{{ end }}' | grep -q .; then
        echo_error "Volume $BACKUP_DIR não está montado no container $CONTAINER_NAME"
        echo_info "Para corrigir, execute:"
        echo_info "  1. docker volume create postgres_backup"
        echo_info "  2. docker volume inspect postgres_backup # Para ver o mountpoint"
        echo_info "  3. Adicione ao container: -v postgres_backup:$BACKUP_DIR"
        return 1
    fi
    return 0
}

# Função principal de restauração (procurar múltiplos formatos)
function do_restore() {
    echo_info "Bancos de dados disponíveis:"
    local DATABASES=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -tAc "SELECT datname FROM pg_database WHERE datistemplate = false;")
    
    select DB in $DATABASES "Cancelar"; do
        if [ "$DB" = "Cancelar" ]; then
            return 0
        elif [ -n "$DB" ]; then
            break
        fi
        echo "Seleção inválida"
    done
    
    echo_info "Backups disponíveis para $DB:"
    # Procurar por ambos os formatos de arquivo
    mapfile -t BACKUPS < <(ls -1 "$BACKUP_DIR" | grep -E "postgres_backup_.*_${DB}\.(backup|sql\.gz)$" || true)
    
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo_error "Nenhum backup encontrado para $DB em $BACKUP_DIR"
        ls -la "$BACKUP_DIR" # Debug
        return 1
    fi
    
    echo "Selecione o backup para restauração:"
    for i in "${!BACKUPS[@]}"; do
        echo "$((i+1))) ${BACKUPS[$i]}"
    done
    
    while true; do
        read -p "Digite o número do backup (ou 0 para cancelar): " selection
        if [ "$selection" = "0" ]; then
            return 0
        elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -le "${#BACKUPS[@]}" ]; then
            BACKUP="${BACKUPS[$((selection-1))]}"
            break
        fi
        echo "Seleção inválida"
    done
    
    echo_warning "ATENÇÃO: A restauração irá substituir TODOS os dados do banco '$DB'"
    read -p "Digite 'sim' para confirmar: " CONFIRM
    if [ "$CONFIRM" != "sim" ]; then
        echo_info "Restauração cancelada pelo usuário"
        return 0
    fi
    
    echo_info "Restaurando $BACKUP em $DB..."
    
    # Descomprimir backup
    gunzip -c "$BACKUP_DIR/$BACKUP" > "$BACKUP_DIR/temp_restore.sql"
    
    # Dropar conexões existentes
    docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB' AND pid <> pg_backend_pid();"
    
    # Restaurar
    if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -d "$DB" -f "/var/backups/postgres/temp_restore.sql"; then
        echo_success "Restauração concluída com sucesso"
    else
        echo_error "Falha na restauração"
        return 1
    fi
    
    # Limpar arquivo temporário
    rm -f "$BACKUP_DIR/temp_restore.sql"
}

# Executar script principal
function main() {
    rotate_log
    echo_info "Iniciando processo de configuração..."

    # Carregar variáveis do .env
    if ! load_env; then
        echo_error "Erro ao carregar variáveis do .env"
        exit 1
    fi

    # Garantir a montagem correta do volume
    if ! check_volume_mount; then
        exit 1
    fi

    # Chamar função de restauração
    do_restore
}

# Iniciar execução
main "$@"

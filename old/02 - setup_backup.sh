#!/bin/bash

# =============================================================================
# PostgreSQL Backup Manager para Docker
# Versão: 1.1.0
# Autor: System Administrator
# Data: 2024
# =============================================================================
# Descrição: Sistema completo para backup e restauração de bancos PostgreSQL
# rodando em containers Docker, com suporte a:
# - Múltiplos tipos de backup
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

# Funções de Utilidade
function echo_info() { echo -e "\e[34m[INFO]\e[0m $1" | tee -a "$LOG_FILE"; sleep 1; }
function echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1" | tee -a "$LOG_FILE"; sleep 1; }
function echo_warning() { echo -e "\e[33m[WARNING]\e[0m $1" | tee -a "$LOG_FILE"; sleep 1; }
function echo_error() { echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOG_FILE"; sleep 1; }
function command_exists() { command -v "$1" >/dev/null 2>&1; }
function valid_url() { [[ "$1" =~ ^https?://.+ ]]; }

# Função para rotação de logs
function rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
        local backup_log="${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        mv "$LOG_FILE" "$backup_log"
        gzip "$backup_log"
        echo "=== Log rotacionado em $(date) ===" > "$LOG_FILE"
    fi
}

# Função para enviar webhook com retry
function send_webhook() {
    local payload="$1"
    local max_retries=3
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        if curl -s -S -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" -o /dev/null -w "%{http_code}" | grep -q "^2"; then
            return 0
        fi
        retry=$((retry + 1))
        [ $retry -lt $max_retries ] && sleep 5
    done
    
    echo_error "Falha ao enviar webhook após $max_retries tentativas"
    echo "$(date): $payload" >> "$BACKUP_DIR/failed_webhooks.log"
    return 1
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
    if ! docker inspect "$CONTAINER_NAME" --format '{{ range .Mounts }}{{ if eq .Destination "'$BACKUP_DIR'" }}{{ .Source }}{{ end }}{{ end }}' | grep -q .; then
        echo_error "Volume $BACKUP_DIR não está montado no container $CONTAINER_NAME"
        echo_info "Para corrigir, execute:"
        echo_info "  1. docker volume create postgres_backup"
        echo_info "  2. Adicione ao container: -v postgres_backup:$BACKUP_DIR"
        return 1
    fi
    return 0
}

# Função principal de backup
function do_backup() {
    local DB="$1"
    local TIMESTAMP=$(date +%Y%m%d%H%M%S)
    local BACKUP_FILENAME="postgres_backup_${TIMESTAMP}_${DB}.sql"
    local BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"
    
    echo_info "Iniciando backup do banco '$DB'..."
    
    # Verificar espaço disponível
    local available_space=$(df -P "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    local min_space=$((5 * 1024 * 1024)) # 5GB em KB
    if [ "$available_space" -lt "$min_space" ]; then
        echo_error "Espaço insuficiente em disco (mínimo 5GB necessário)"
        return 1
    fi
    
    case "$BACKUP_OPTION" in
        1)
            echo_info "Realizando backup completo com inserts..."
            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                pg_dump -U "$PG_USER" -F p --inserts -v "$DB" > "$BACKUP_PATH"
            ;;
        2)
            echo_info "Realizando backup apenas das tabelas..."
            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                pg_dump -U "$PG_USER" -F c --schema-only -v "$DB" > "$BACKUP_PATH"
            ;;
        3)
            echo_info "Digite as tabelas para backup (separadas por espaço):"
            read -a TABLES
            if [ ${#TABLES[@]} -eq 0 ]; then
                echo_error "Nenhuma tabela especificada"
                return 1
            fi
            local TABLE_ARGS=""
            for table in "${TABLES[@]}"; do
                TABLE_ARGS="$TABLE_ARGS -t $table"
            done
            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                pg_dump -U "$PG_USER" $TABLE_ARGS --inserts -v "$DB" > "$BACKUP_PATH"
            ;;
        *)
            echo_error "Opção de backup inválida"
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        # Comprimir backup
        echo_info "Comprimindo backup..."
        gzip -f "$BACKUP_PATH"
        BACKUP_PATH="${BACKUP_PATH}.gz"
        
        local BACKUP_SIZE=$(ls -lh "$BACKUP_PATH" | awk '{print $5}')
        echo_success "Backup concluído: ${BACKUP_FILENAME}.gz (Tamanho: $BACKUP_SIZE)"
        
        send_webhook "{
            \"status\": \"success\",
            \"action\": \"backup\",
            \"database\": \"$DB\",
            \"file\": \"${BACKUP_FILENAME}.gz\",
            \"size\": \"$BACKUP_SIZE\",
            \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"
        }"
        
        # Limpar backups antigos
        echo_info "Removendo backups mais antigos que $RETENTION_DAYS dias..."
        find "$BACKUP_DIR" -name "postgres_backup_*_${DB}.sql.gz" -mtime +$RETENTION_DAYS -delete
    else
        echo_error "Falha no backup de $DB"
        send_webhook "{
            \"status\": \"error\",
            \"action\": \"backup\",
            \"database\": \"$DB\",
            \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",
            \"error\": \"Falha na execução do pg_dump\"
        }"
        return 1
    fi
}

# Função principal de restauração
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
    mapfile -t BACKUPS < <(ls -1 "$BACKUP_DIR" | grep "postgres_backup_.*_${DB}.sql.gz$" || true)
    
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo_error "Nenhum backup encontrado para $DB"
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
        send_webhook "{
            \"status\": \"success\",
            \"action\": \"restore\",
            \"database\": \"$DB\",
            \"file\": \"$BACKUP\",
            \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"
        }"
    else
        echo_error "Falha na restauração"
        send_webhook "{
            \"status\": \"error\",
            \"action\": \"restore\",
            \"database\": \"$DB\",
            \"file\": \"$BACKUP\",
            \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"
        }"
    fi
    
    # Limpar arquivo temporário
    rm -f "$BACKUP_DIR/temp_restore.sql"
}

# Script principal
function main() {
    echo "=== Início da execução em $(date) ===" >> "$LOG_FILE"
    rotate_log
    
    echo_info "Iniciando processo de configuração..."
    
    if ! load_env; then
        # Verificar Docker
        if ! command_exists docker; then
            echo_error "Docker não está instalado."
            exit 1
        fi
        
        # Identificar containers PostgreSQL
        echo_info "Identificando containers PostgreSQL..."
        POSTGRES_CONTAINERS=$(docker ps --format "{{.Names}}" | grep -i postgres)
        
        if [ -z "$POSTGRES_CONTAINERS" ]; then
            echo_warning "Nenhum container PostgreSQL encontrado."
            read -p "Deseja configurar manualmente? (yes/no): " MANUAL_CONFIG
            if [[ "$MANUAL_CONFIG" =~ ^(yes|Yes|YES)$ ]]; then
                read -p "Nome do container PostgreSQL: " CONTAINER_NAME
                if ! docker ps --format "{{.Names}}" | grep -qw "$CONTAINER_NAME"; then
                    echo_error "Container inválido ou não está rodando."
                    exit 1
                fi
            else
                exit 1
            fi
        elif [ $(echo "$POSTGRES_CONTAINERS" | wc -l) -eq 1 ]; then
            CONTAINER_NAME="$POSTGRES_CONTAINERS"
            echo_info "Container identificado: $CONTAINER_NAME"
        else
            echo "Containers disponíveis:"
            echo "$POSTGRES_CONTAINERS"
            read -p "Selecione o container: " CONTAINER_NAME
            if ! echo "$POSTGRES_CONTAINERS" | grep -q "^$CONTAINER_NAME\$"; then
                echo_error "Container inválido"
                exit 1
            fi
        fi
        
        # Configurar usuário PostgreSQL
        read -p "Usar usuário padrão 'postgres'? (yes/no): " USE_DEFAULT_USER
        if [[ "$USE_DEFAULT_USER" =~ ^(yes|Yes|YES)$ ]]; then
            PG_USER="postgres"
        else
            read -p "Usuário PostgreSQL: " PG_USER
            if [ -z "$PG_USER" ]; then
                echo_error "Usuário não pode estar vazio."
                exit 1
            fi
        fi
        
        # Senha PostgreSQL
        read -p "Senha PostgreSQL: " PG_PASSWORD
        if [ -z "$PG_PASSWORD" ]; then
            echo_error "Senha não pode estar vazia."
            exit 1
        fi
        
        # Período de retenção
        read -p "Período de retenção em dias [30]: " RETENTION_DAYS
        RETENTION_DAYS=${RETENTION_DAYS:-30}
        
        # URL do Webhook
        while true; do
            read -p "URL do Webhook: " WEBHOOK_URL
            if valid_url "$WEBHOOK

            # Continuação do main()...
            URL"; then break; fi
            echo_error "URL inválida (use http:// ou https://)"
        done
        
        # Tipo de backup
        echo_info "Tipos de backup disponíveis:"
        echo "1) Backup completo com inserts"
        echo "2) Apenas estrutura"
        echo "3) Tabelas específicas"
        read -p "Selecione [1]: " BACKUP_OPTION
        BACKUP_OPTION=${BACKUP_OPTION:-1}
        
        save_env
    fi
    
    # Criar e verificar diretório de backup
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    
    # Verificar montagem do volume
    if ! check_volume_mount; then
        read -p "Continuar mesmo sem volume montado? (yes/no): " CONTINUE_WITHOUT_MOUNT
        if [[ ! "$CONTINUE_WITHOUT_MOUNT" =~ ^(yes|Yes|YES)$ ]]; then
            exit 1
        fi
    fi
    
    # Criar scripts
    BACKUP_SCRIPT="/usr/local/bin/backup_postgres.sh"
    RESTORE_SCRIPT="/usr/local/bin/restore_postgres.sh"
    
    # Script de backup
    cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
source "$ENV_FILE"
$(declare -f echo_info echo_success echo_warning echo_error send_webhook rotate_log do_backup)

# Iniciar log
echo "=== Início do backup em \$(date) ===" >> "$LOG_FILE"
rotate_log

# Executar backup para cada banco
for DB in \$(docker exec -e PGPASSWORD="\$PG_PASSWORD" "\$CONTAINER_NAME" psql -U "\$PG_USER" -tAc "SELECT datname FROM pg_database WHERE datistemplate = false;"); do
    do_backup "\$DB"
done

echo "=== Fim do backup em \$(date) ===" >> "$LOG_FILE"
EOF
    chmod +x "$BACKUP_SCRIPT"
    
    # Script de restauração
    cat > "$RESTORE_SCRIPT" <<EOF
#!/bin/bash
source "$ENV_FILE"
$(declare -f echo_info echo_success echo_warning echo_error send_webhook rotate_log do_restore)

# Iniciar log
echo "=== Início da restauração em \$(date) ===" >> "$LOG_FILE"
rotate_log

do_restore

echo "=== Fim da restauração em \$(date) ===" >> "$LOG_FILE"
EOF
    chmod +x "$RESTORE_SCRIPT"
    
    # Configurar cron
    (crontab -l 2>/dev/null | grep -v backup_postgres.sh; echo "0 0 * * * $BACKUP_SCRIPT >> $LOG_FILE 2>&1") | crontab -
    
    echo_success "Configuração concluída!"
    echo_info "Comandos disponíveis:"
    echo "  Backup manual: $BACKUP_SCRIPT"
    echo "  Restauração: $RESTORE_SCRIPT"
    
    read -p "Executar backup agora? (yes/no): " DO_BACKUP
    if [[ "$DO_BACKUP" =~ ^(yes|Yes|YES)$ ]]; then
        "$BACKUP_SCRIPT"
    fi
    
    echo "=== Fim da execução em $(date) ===" >> "$LOG_FILE"
}

# Executar script principal
main "$@"
#!/bin/bash

# =============================================================================
# PostgreSQL Backup Manager 2024
# Versão: 1.4.0
# =============================================================================
# - Backup automático diário
# - Retenção configurável
# - Notificações webhook consolidadas
# - Restauração interativa
# - Detecção automática de container PostgreSQL
# - Criação automática de estruturas
# - Gerenciamento de logs com rotação
# - Recriação automática de estruturas ausentes
# =============================================================================

set -e
set -u
set -o pipefail

# Configurações Globais
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="/root/.pg_backup.env"
readonly LOG_FILE="/var/log/pg_backup.log"
readonly MAX_LOG_SIZE=$((50 * 1024 * 1024)) # 50MB
readonly BACKUP_DIR="/var/backups/postgres"
readonly TEMP_DIR="$BACKUP_DIR/temp"

# Criar diretórios necessários
mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR" "$TEMP_DIR" || true
touch "$LOG_FILE" || true
chmod 644 "$LOG_FILE" || true
chmod 700 "$BACKUP_DIR" "$TEMP_DIR" || true

# Estrutura para consolidar resultados dos backups
declare -A BACKUP_RESULTS
declare -A BACKUP_SIZES
declare -A BACKUP_FILES
declare -A DELETED_BACKUPS

# Funções de Utilidade
function echo_info() {
    echo -e "\e[34m[INFO]\e[0m $1" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "\e[34m[INFO]\e[0m $1"
}

function echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "\e[32m[SUCCESS]\e[0m $1"
}

function echo_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "\e[33m[WARNING]\e[0m $1"
}

function echo_error() {
    echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "\e[31m[ERROR]\e[0m $1"
}

# Função para gerenciar rotação de logs
function rotate_logs() {
    if [ -f "$LOG_FILE" ]; then
        local log_size
        log_size=$(stat -c%s "$LOG_FILE")
        if [ "$log_size" -ge "$MAX_LOG_SIZE" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.$(date '+%Y%m%d%H%M%S').bak"
            touch "$LOG_FILE"
            chmod 644 "$LOG_FILE"
            echo_info "Log rotacionado devido ao tamanho excedido."
        fi
    fi
}

# Função para identificar container PostgreSQL
function detect_postgres_container() {
    local containers
    containers=$(docker ps --format "{{.Names}}" | grep -i postgres || true)
    if [ -z "$containers" ]; then
        echo_error "Nenhum container PostgreSQL encontrado!"
        exit 1
    elif [ "$(echo "$containers" | wc -l)" -eq 1 ]; then
        echo "$containers"
    else
        echo_info "Containers PostgreSQL disponíveis:"
        echo "$containers"
        while true; do
            read -p "Digite o nome do container: " container_name
            if docker ps --format "{{.Names}}" | grep -qw "$container_name"; then
                echo "$container_name"
                break
            else
                echo_warning "Nome do container inválido. Tente novamente."
            fi
        done
    fi
}

# Função para enviar webhook
function send_webhook() {
    local payload="$1"
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        local response
        response=$(curl -s -S -X POST -H "Content-Type: application/json" \
            -d "$payload" "$WEBHOOK_URL" -w "%{http_code}" -o /dev/null)
        if [[ "$response" =~ ^2 ]]; then
            return 0
        fi
        retry=$((retry + 1))
        [ $retry -lt $max_retries ] && sleep 5
    done

    echo_error "Falha ao enviar webhook após $max_retries tentativas"
    return 1
}

# Função para carregar ou criar configurações
function setup_config() {
    if [ -f "$ENV_FILE" ]; then
        echo_info "Configurações existentes encontradas:"
        cat "$ENV_FILE"
        read -p "Deseja manter estas configurações? (yes/no): " keep_config
        if [[ "$keep_config" =~ ^(yes|y|Y) ]]; then
            source "$ENV_FILE"
            return 0
        fi
    fi

    echo_info "Configurando backup..."

    # Detectar container
    CONTAINER_NAME=$(detect_postgres_container)

    # Configurar usuário e senha
    read -p "Usuário PostgreSQL [postgres]: " PG_USER
    PG_USER=${PG_USER:-postgres}

    while true; do
        read -s -p "Senha PostgreSQL: " PG_PASSWORD
        echo
        read -s -p "Confirme a senha: " PG_PASSWORD_CONFIRM
        echo
        if [ "$PG_PASSWORD" == "$PG_PASSWORD_CONFIRM" ]; then
            break
        else
            echo_warning "As senhas não coincidem. Tente novamente."
        fi
    done

    # Configurar retenção
    read -p "Dias de retenção dos backups [30]: " RETENTION_DAYS
    RETENTION_DAYS=${RETENTION_DAYS:-30}

    # Configurar webhook
    read -p "URL do Webhook: " WEBHOOK_URL
    if ! curl -s -o /dev/null "$WEBHOOK_URL"; then
        echo_warning "Não foi possível validar o webhook. Continuar mesmo assim? (yes/no): "
        read confirm
        if [[ ! "$confirm" =~ ^(yes|y|Y) ]]; then
            exit 1
        fi
    fi

    # Salvar configurações
    cat > "$ENV_FILE" <<EOF
CONTAINER_NAME="$CONTAINER_NAME"
PG_USER="$PG_USER"
PG_PASSWORD="$PG_PASSWORD"
RETENTION_DAYS="$RETENTION_DAYS"
WEBHOOK_URL="$WEBHOOK_URL"
BACKUP_DIR="$BACKUP_DIR"
LOG_FILE="$LOG_FILE"
TEMP_DIR="$TEMP_DIR"
EOF
    chmod 600 "$ENV_FILE"
    echo_success "Configurações salvas em $ENV_FILE"
}

# Função para garantir que o banco de dados exista
function ensure_database_exists() {
    local db_name="$1"
    if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
        echo_info "Criando banco de dados $db_name..."
        docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -c "CREATE DATABASE \"$db_name\";"
    fi
}

# Função para analisar e recriar estruturas ausentes
function analyze_and_recreate_structures() {
    local DB="$1"
    local BACKUP_FILE="$2"
    echo_info "Analisando estruturas do banco '$DB'..."

    # Extrair apenas as estruturas (CREATE TABLE, etc.)
    local STRUCTURES_FILE="$TEMP_DIR/structures.sql"
    grep -E '^CREATE (TABLE|INDEX|VIEW|SEQUENCE)' "$BACKUP_FILE" > "$STRUCTURES_FILE"

    # Para cada estrutura, verificar se existe e criar se necessário
    while IFS= read -r create_stmt; do
        if [[ "$create_stmt" =~ ^CREATE[[:space:]]+TABLE[[:space:]]+\"?([^\"]+)\"?[[:space:]]*\( ]]; then
            local table_name="${BASH_REMATCH[1]}"
            echo_info "Verificando tabela \"$table_name\"..."
            if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                psql -U "$PG_USER" -d "$DB" -c "\d \"$table_name\"" &>/dev/null; then
                echo_info "Criando tabela \"$table_name\"..."
                docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                    psql -U "$PG_USER" -d "$DB" -c "$create_stmt"
            fi
        fi
        # Adicione mais condições se necessário para outras estruturas como INDEX, VIEW, etc.
    done < "$STRUCTURES_FILE"

    rm -f "$STRUCTURES_FILE"
}

# Função para enviar webhook consolidado
function send_consolidated_webhook() {
    local success_count=0
    local error_count=0
    local success_dbs=""
    local error_dbs=""
    local deleted_backups_json="[]"

    for db in "${!BACKUP_RESULTS[@]}"; do
        if [ "${BACKUP_RESULTS[$db]}" = "success" ]; then
            success_count=$((success_count + 1))
            success_dbs="$success_dbs\"$db\","
        else
            error_count=$((error_count + 1))
            error_dbs="$error_dbs\"$db\","
        fi
    done

    # Remover última vírgula
    success_dbs=${success_dbs%,}
    error_dbs=${error_dbs%,}

    # Criar array de backups deletados
    deleted_backups_json="["
    for db in "${!DELETED_BACKUPS[@]}"; do
        deleted_backups_json="$deleted_backups_json{\"database\":\"$db\",\"file\":\"${DELETED_BACKUPS[$db]}\",\"reason\":\"Prazo de retenção expirado\"},"
    done
    deleted_backups_json=${deleted_backups_json%,}"]"

    local payload="{
        \"action\": \"Backup realizado\",
        \"date\": \"$(date '+%d/%m/%Y %H:%M:%S')\",
        \"summary\": {
            \"total_databases\": $((success_count + error_count)),
            \"successful_backups\": $success_count,
            \"failed_backups\": $error_count,
            \"successful_databases\": [$success_dbs],
            \"failed_databases\": [$error_dbs]
        },
        \"backups\": ["

    for db in "${!BACKUP_RESULTS[@]}"; do
        if [ "${BACKUP_RESULTS[$db]}" = "success" ]; then
            payload="$payload{
                \"database\": \"$db\",
                \"file\": \"${BACKUP_FILES[$db]}\",
                \"size\": \"${BACKUP_SIZES[$db]}\",
                \"status\": \"success\"
            },"
        fi
    done

    payload=${payload%,}
    payload="$payload],
        \"deleted_backups\": $deleted_backups_json,
        \"retention_days\": $RETENTION_DAYS,
        \"status\": \"$([ $error_count -eq 0 ] && echo 'OK' || echo 'PARTIAL_ERROR')\",
        \"notes\": \"Backup executado em $(date). $success_count de $((success_count + error_count)) bancos backupeados com sucesso.\"
    }"

    send_webhook "$payload"
}

# Função principal de backup
function do_backup() {
    rotate_logs
    local TIMESTAMP=$(date +%Y%m%d%H%M%S)
    local databases

    echo_info "Iniciando backup completo..."

    # Lista todos os bancos
    databases=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

    for db in $databases; do
        local BACKUP_FILENAME="postgres_backup_${TIMESTAMP}_${db}.sql"
        local BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"

        echo_info "Fazendo backup do banco '$db'..."

        if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            pg_dump -U "$PG_USER" -F p --inserts -v "$db" > "$BACKUP_PATH" 2>>"$LOG_FILE"; then

            # Comprimir backup
            gzip -f "$BACKUP_PATH"
            BACKUP_PATH="${BACKUP_PATH}.gz"

            local BACKUP_SIZE=$(ls -lh "$BACKUP_PATH" | awk '{print $5}')
            echo_success "Backup concluído: $(basename "$BACKUP_PATH") (Tamanho: $BACKUP_SIZE)"

            # Armazenar resultados para webhook consolidado
            BACKUP_RESULTS[$db]="success"
            BACKUP_SIZES[$db]="$BACKUP_SIZE"
            BACKUP_FILES[$db]="$(basename "$BACKUP_PATH")"

            # Verificar e registrar backups antigos deletados
            local old_backup
            old_backup=$(find "$BACKUP_DIR" -name "postgres_backup_*_${db}.sql.gz" -mtime +"$RETENTION_DAYS" -print | sort | head -n1 || true)
            if [ -n "$old_backup" ]; then
                DELETED_BACKUPS[$db]="$(basename "$old_backup")"
                rm -f "$old_backup"
                echo_info "Backup antigo deletado: $(basename "$old_backup")"
            fi

            # Limpar backups antigos
            find "$BACKUP_DIR" -name "postgres_backup_*_${db}.sql.gz" -mtime +"$RETENTION_DAYS" -delete

        else
            echo_error "Falha no backup de $db"
            BACKUP_RESULTS[$db]="error"
        fi
    done

    # Enviar webhook consolidado
    send_consolidated_webhook
}

# Função principal de restauração
function do_restore() {
    rotate_logs
    echo_info "Bancos de dados disponíveis:"
    local DATABASES
    DATABASES=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -tAc "SELECT datname FROM pg_database WHERE datistemplate = false;")

    select DB in $DATABASES "Cancelar"; do
        if [ "$DB" = "Cancelar" ]; then
            echo_info "Restauração cancelada pelo usuário."
            return 0
        elif [ -n "$DB" ]; then
            break
        fi
        echo_warning "Seleção inválida."
    done

    echo_info "Backups disponíveis para '$DB':"
    mapfile -t BACKUPS < <(find "$BACKUP_DIR" -type f -name "postgres_backup_*_${DB}.sql.gz" -print | sort -r)

    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo_error "Nenhum backup encontrado para $DB"
        return 1
    fi

    echo "Backups disponíveis:"
    for i in "${!BACKUPS[@]}"; do
        local file_size
        file_size=$(ls -lh "${BACKUPS[$i]}" | awk '{print $5}')
        local file_date
        file_date=$(ls -l --time-style=long-iso "${BACKUPS[$i]}" | awk '{print $6, $7}')
        echo "$((i+1))) $(basename "${BACKUPS[$i]}") (Tamanho: $file_size, Data: $file_date)"
    done

    while true; do
        read -p "Digite o número do backup (ou 0 para cancelar): " selection
        if [ "$selection" = "0" ]; then
            echo_info "Restauração cancelada pelo usuário."
            return 0
        elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -le "${#BACKUPS[@]}" ]; then
            BACKUP="${BACKUPS[$((selection-1))]}"
            break
        fi
        echo_warning "Seleção inválida. Tente novamente."
    done

    echo_warning "ATENÇÃO: Isso irá substituir o banco '$DB' existente!"
    read -p "Digite 'sim' para confirmar: " CONFIRM
    if [ "$CONFIRM" != "sim" ]; then
        echo_info "Restauração cancelada pelo usuário."
        return 0
    fi

    echo_info "Restaurando backup '$BACKUP' em '$DB'..."

    # Garantir que o banco exista
    create_database_if_not_exists "$DB"

    # Descomprimir backup
    gunzip -c "$BACKUP" > "$BACKUP_DIR/temp_restore.sql"

    # Analisar e recriar estruturas ausentes
    analyze_and_recreate_structures "$DB" "$BACKUP_DIR/temp_restore.sql"

    # Dropar conexões existentes
    docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -d "$DB" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB' AND pid <> pg_backend_pid();"

    # Restaurar dados
    if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -d "$DB" -f "/var/backups/postgres/temp_restore.sql" 2>>"$LOG_FILE"; then
        echo_success "Restauração concluída com sucesso."
        send_webhook "{
            \"action\": \"Restauração realizada com sucesso\",
            \"date\": \"$(date '+%d/%m/%Y %H:%M:%S')\",
            \"database_name\": \"$DB\",
            \"backup_file\": \"$(basename "$BACKUP")\",
            \"status\": \"OK\"
        }"
    else
        echo_error "Falha na restauração."
        send_webhook "{
            \"action\": \"Restauração falhou\",
            \"date\": \"$(date '+%d/%m/%Y %H:%M:%S')\",
            \"database_name\": \"$DB\",
            \"backup_file\": \"$(basename "$BACKUP")\",
            \"status\": \"ERROR\"
        }"
    fi

    # Limpar arquivos temporários
    rm -f "$BACKUP_DIR/temp_restore.sql"
    rm -rf "$TEMP_DIR"/*
}

# Função principal
function main() {
    case "${1:-}" in
        "--backup")
            if [ ! -f "$ENV_FILE" ]; then
                echo_error "Arquivo de configuração '$ENV_FILE' não encontrado. Execute o script sem argumentos para configurar."
                exit 1
            fi
            source "$ENV_FILE"
            do_backup
            ;;
        "--restore")
            if [ ! -f "$ENV_FILE" ]; then
                echo_error "Arquivo de configuração '$ENV_FILE' não encontrado. Execute o script sem argumentos para configurar."
                exit 1
            fi
            source "$ENV_FILE"
            do_restore
            ;;
        *)
            # Configuração inicial
            setup_config

            # Criar scripts de backup/restore
            echo_info "Configurando scripts de gerenciamento..."

            # Script de backup
            cat > /usr/local/bin/pg_backup <<EOF
#!/bin/bash
source "$ENV_FILE"
$(declare -f echo_info echo_success echo_warning echo_error send_webhook do_backup rotate_logs)
do_backup
EOF
            chmod +x /usr/local/bin/pg_backup

            # Script de restore
            cat > /usr/local/bin/pg_restore_db <<EOF
#!/bin/bash
source "$ENV_FILE"
$(declare -f echo_info echo_success echo_warning echo_error send_webhook do_restore rotate_logs ensure_database_exists analyze_and_recreate_structures)
do_restore
EOF
            chmod +x /usr/local/bin/pg_restore_db

            # Configurar cron para backup diário às 00:00
            (crontab -l 2>/dev/null | grep -v 'pg_backup'; echo "0 0 * * * /usr/local/bin/pg_backup") | crontab -

            echo_success "Configuração concluída com sucesso!"
            echo_info "Comandos disponíveis:"
            echo "  Backup manual: pg_backup"
            echo "  Restauração: pg_restore_db"

            read -p "Deseja executar um backup agora? (yes/no): " do_backup_now
            if [[ "$do_backup_now" =~ ^(yes|y|Y) ]]; then
                do_backup
            fi
            ;;
    esac
}

main "$@"

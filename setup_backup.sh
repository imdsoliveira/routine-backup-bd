#!/bin/bash

# =============================================================================
# PostgreSQL Backup Manager 2024
# Versão: 1.6.0
# =============================================================================
# - Backup automático diário
# - Retenção configurável
# - Notificações webhook consolidadas
# - Restauração interativa (com opção de escolher bancos específicos)
# - Detecção automática de container PostgreSQL
# - Criação automática de estruturas ausentes
# - Criação automática de databases ausentes antes da restauração
# - Gerenciamento de logs com rotação
# - Verificação pré-backup/restauração (teste de conexão)
# - Correção na ordem das operações
# - Atualização flexível de configurações (.env)
# - Menu interativo pós-configuração
# =============================================================================

set -e
set -u
set -o pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # Sem cor

# Caminhos e arquivos globais
SCRIPT_DIR="/usr/local/bin"
ENV_FILE="/root/.pg_backup.env"
LOG_FILE="/var/log/pg_backup.log"
BACKUP_DIR="/var/backups/postgres"
TEMP_DIR="$BACKUP_DIR/temp"
MAX_LOG_SIZE=$((50 * 1024 * 1024)) # 50MB

# Criar diretórios necessários
mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR" "$TEMP_DIR" || true
touch "$LOG_FILE" || true
chmod 644 "$LOG_FILE" || true
chmod 700 "$BACKUP_DIR" "$TEMP_DIR" || true

# Estruturas para consolidar resultados
declare -A BACKUP_RESULTS
declare -A BACKUP_SIZES
declare -A BACKUP_FILES
declare -A DELETED_BACKUPS

###############################################################################
# Funções de Log
###############################################################################
echo_info() {
    echo -e "${YELLOW}[INFO]${NC} $1" | tee -a "$LOG_FILE" >/dev/null 2>&1 || echo -e "${YELLOW}[INFO]${NC} $1"
}

echo_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE" >/dev/null 2>&1 || echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE" >/dev/null 2>&1 || echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE" >/dev/null 2>&1 || echo -e "${RED}[ERROR]${NC} $1"
}

###############################################################################
# Rotação de logs
###############################################################################
rotate_logs() {
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

###############################################################################
# Função para detectar container PostgreSQL
###############################################################################
detect_postgres_container() {
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

###############################################################################
# Webhook
###############################################################################
send_webhook() {
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

###############################################################################
# Carregar ou criar configurações (.env)
###############################################################################
setup_config() {
    local CONFIG_EXISTS=false
    local TEMP_ENV_FILE="/tmp/pg_backup.env.tmp"

    if [ -f "$ENV_FILE" ]; then
        CONFIG_EXISTS=true
        cp "$ENV_FILE" "$TEMP_ENV_FILE"
    elif [ -f "/etc/pg_backup.env" ]; then
        CONFIG_EXISTS=true
        cp "/etc/pg_backup.env" "$TEMP_ENV_FILE"
        ENV_FILE="/etc/pg_backup.env"
    elif [ -f "$HOME/.pg_backup.env" ]; then
        CONFIG_EXISTS=true
        cp "$HOME/.pg_backup.env" "$TEMP_ENV_FILE"
        ENV_FILE="$HOME/.pg_backup.env"
    fi

    if [ "$CONFIG_EXISTS" = true ]; then
        echo_info "Configurações existentes encontradas em: $ENV_FILE"
        echo "Configurações atuais:"
        echo "----------------------------------------"
        grep -v "PG_PASSWORD" "$ENV_FILE" | sed 's/^/  /'
        grep "PG_PASSWORD" "$ENV_FILE" | sed 's/^/  /'
        echo "----------------------------------------"
        read -p "Deseja manter estas configurações? (yes/no): " keep_config
        if [[ ! "$keep_config" =~ ^(yes|y|Y)$ ]]; then
            source "$ENV_FILE"
            # Atualizar configs
            echo_info "Atualizando configurações..."
            # Detectar container novamente (garantindo atualização)
            CONTAINER_NAME=$(detect_postgres_container)
            
            read -p "Usuário PostgreSQL [$PG_USER]: " new_user
            PG_USER=${new_user:-$PG_USER}

            while true; do
                read -s -p "Senha PostgreSQL (Enter para manter atual): " new_password
                echo
                if [ -n "$new_password" ]; then
                    read -s -p "Confirme a senha: " confirm_password
                    echo
                    if [ "$new_password" = "$confirm_password" ]; then
                        PG_PASSWORD="$new_password"
                        break
                    else
                        echo_warning "As senhas não coincidem. Tente novamente."
                    fi
                else
                    break
                fi
            done

            read -p "Dias de retenção dos backups [$RETENTION_DAYS]: " new_retention
            RETENTION_DAYS=${new_retention:-$RETENTION_DAYS}

            read -p "URL do Webhook [$WEBHOOK_URL]: " new_webhook
            WEBHOOK_URL=${new_webhook:-$WEBHOOK_URL}
            if ! curl -s -o /dev/null "$WEBHOOK_URL"; then
                echo_warning "Não foi possível validar o webhook. Continuar mesmo assim? (yes/no): "
                read confirm
                if [[ ! "$confirm" =~ ^(yes|y|Y)$ ]]; then
                    exit 1
                fi
            fi
        else
            # Apenas manter configurações
            source "$ENV_FILE"
            return 0
        fi
    else
        echo_info "Configurando novo backup..."
        CONTAINER_NAME=$(detect_postgres_container)

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

        read -p "Dias de retenção dos backups [30]: " RETENTION_DAYS
        RETENTION_DAYS=${RETENTION_DAYS:-30}

        read -p "URL do Webhook: " WEBHOOK_URL
        if ! curl -s -o /dev/null "$WEBHOOK_URL"; then
            echo_warning "Não foi possível validar o webhook. Continuar mesmo assim? (yes/no): "
            read confirm
            if [[ ! "$confirm" =~ ^(yes|y|Y)$ ]]; then
                exit 1
            fi
        fi
    fi

    local CONFIG_CONTENT
    CONFIG_CONTENT=$(cat <<EOF
CONTAINER_NAME="$CONTAINER_NAME"
PG_USER="$PG_USER"
PG_PASSWORD="$PG_PASSWORD"
RETENTION_DAYS="$RETENTION_DAYS"
WEBHOOK_URL="$WEBHOOK_URL"
BACKUP_DIR="$BACKUP_DIR"
LOG_FILE="$LOG_FILE"
TEMP_DIR="$TEMP_DIR"
EOF
    )

    echo "$CONFIG_CONTENT" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    # Backup em /etc
    if [ -w /etc ]; then
        echo "$CONFIG_CONTENT" > "/etc/pg_backup.env"
        chmod 600 "/etc/pg_backup.env"
    fi

    # Backup no home do usuário
    echo "$CONFIG_CONTENT" > "$HOME/.pg_backup.env"
    chmod 600 "$HOME/.pg_backup.env"

    echo "Configurações salvas:"
    echo "----------------------------------------"
    grep -v "PG_PASSWORD" <<< "$CONFIG_CONTENT" | sed 's/^/  /'
    grep "PG_PASSWORD" <<< "$CONFIG_CONTENT" | sed 's/^/  /'
    echo "----------------------------------------"

    echo_success "Configurações salvas com redundância em:"
    echo "  - $ENV_FILE"
    [ -f "/etc/pg_backup.env" ] && echo "  - /etc/pg_backup.env"
    echo "  - $HOME/.pg_backup.env"

    [ -f "$TEMP_ENV_FILE" ] && rm -f "$TEMP_ENV_FILE"
}

###############################################################################
# Verificar e atualizar container
###############################################################################
verify_container() {
    local current_container="$1"
    if ! docker ps --format "{{.Names}}" | grep -qw "^${current_container}$"; then
        echo_warning "Container '$current_container' não encontrado ou não está rodando."
        echo_info "Detectando container PostgreSQL..."
        local new_container
        new_container=$(detect_postgres_container)
        if [ "$new_container" != "$current_container" ]; then
            echo_info "Atualizando container para: $new_container"
            sed -i "s/CONTAINER_NAME=\".*\"/CONTAINER_NAME=\"$new_container\"/" "$ENV_FILE"
            CONTAINER_NAME="$new_container"
        fi
    fi
}

###############################################################################
# Testar conexão ao banco
###############################################################################
test_database_connection() {
    echo_info "Testando conexão com o banco de dados..."
    if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -c "SELECT 1;" >/dev/null 2>&1; then
        echo_error "Falha na conexão com o banco de dados. Verifique as configurações."
        exit 1
    fi
    echo_success "Conexão com o banco de dados estabelecida com sucesso."
}

###############################################################################
# Funções de verificação e criação de bancos
###############################################################################
ensure_database_exists() {
    local db_name="$1"
    if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
        echo_info "Criando banco de dados '$db_name'..."
        docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -c "CREATE DATABASE \"$db_name\" WITH TEMPLATE template0;"
    fi
}

create_database_if_not_exists() {
    local db_name="$1"
    ensure_database_exists "$db_name"
}

ensure_backup_possible() {
    local db="$1"
    if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -lqt | cut -d \| -f 1 | grep -qw "$db"; then
        echo_error "Banco de dados '$db' não existe"
        return 1
    fi
    return 0
}

###############################################################################
# Analisar e recriar estruturas ausentes
###############################################################################
analyze_and_recreate_structures() {
    local DB="$1"
    local BACKUP_FILE="$2"
    echo_info "Analisando estruturas do banco '$DB'..."

    local SEQUENCES_FILE="$TEMP_DIR/sequences.sql"
    local TABLES_FILE="$TEMP_DIR/tables.sql"
    local INDEXES_FILE="$TEMP_DIR/indexes.sql"

    grep -E '^CREATE SEQUENCE' "$BACKUP_FILE" > "$SEQUENCES_FILE" || true
    grep -E '^CREATE TABLE' "$BACKUP_FILE" > "$TABLES_FILE" || true
    grep -E '^CREATE INDEX' "$BACKUP_FILE" > "$INDEXES_FILE" || true

    for file in "$SEQUENCES_FILE" "$TABLES_FILE" "$INDEXES_FILE"; do
        [ -f "$file" ] || continue
        while IFS= read -r create_stmt; do
            if [[ "$create_stmt" =~ ^CREATE[[:space:]]+(SEQUENCE|TABLE|INDEX)[[:space:]]+\"?([^\"]+)\"?[[:space:]]* ]]; then
                local structure_type="${BASH_REMATCH[1]}"
                local structure_name="${BASH_REMATCH[2]}"
                echo_info "Verificando $structure_type \"$structure_name\"..."

                case "$structure_type" in
                    SEQUENCE)
                        if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                            psql -U "$PG_USER" -d "$DB" -c "\ds \"$structure_name\"" &>/dev/null; then
                            echo_info "Criando sequência \"$structure_name\"..."
                            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                                psql -U "$PG_USER" -d "$DB" -c "$create_stmt"
                        fi
                        ;;
                    TABLE)
                        if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                            psql -U "$PG_USER" -d "$DB" -c "\d \"$structure_name\"" &>/dev/null; then
                            echo_info "Criando tabela \"$structure_name\"..."
                            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                                psql -U "$PG_USER" -d "$DB" -c "$create_stmt"
                        fi
                        ;;
                    INDEX)
                        if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                            psql -U "$PG_USER" -d "$DB" -c "\di \"$structure_name\"" &>/dev/null; then
                            echo_info "Criando índice \"$structure_name\"..."
                            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                                psql -U "$PG_USER" -d "$DB" -c "$create_stmt"
                        fi
                        ;;
                esac
            fi
        done < "$file"
    done

    rm -f "$SEQUENCES_FILE" "$TABLES_FILE" "$INDEXES_FILE"
}

###############################################################################
# Funções de Progresso (opcional)
###############################################################################
show_progress() {
    local current=$1
    local total=$2
    local operation="$3"
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))

    printf "\r\033[K"
    printf "Progresso: ["
    printf "%${filled}s" '' | tr ' ' '#'
    printf "%${empty}s" '' | tr ' ' '-'
    printf "] %3d%%" "$percentage"
    if [ -n "$operation" ]; then
        printf " %s" "$operation"
    fi
}

prepare_sql_with_progress() {
    local input_file="$1"
    local output_file="$2"
    local progress_file="$3"
    local operation_file="$4"

    awk -v progress_file="$progress_file" -v operation_file="$operation_file" '
    /^(SET|CREATE|ALTER|COPY|INSERT)/ {
        operation = $0
        if ($1 == "COPY") {
            operation = "Copiando dados para tabela " $2
        } else if ($1 == "CREATE" && $2 == "TABLE") {
            operation = "Criando tabela " $3
        } else if ($1 == "CREATE" && $2 == "INDEX") {
            operation = "Criando índice " $3
        } else if ($1 == "ALTER" && $2 == "TABLE") {
            operation = "Alterando tabela " $3
        }
        gsub(/"/, "\\\"", operation)
        print $0;
        print "\\! (echo $(($(cat \"" progress_file "\")) + 1) > \"" progress_file "\"; echo \"" operation "\" > \"" operation_file "\");"
    }
    !/^(SET|CREATE|ALTER|COPY|INSERT)/ {
        print $0;
    }
    ' "$input_file" > "$output_file"
}

###############################################################################
# Enviar webhook consolidado (para backup completo)
###############################################################################
send_consolidated_webhook_complete() {
    local success_count=0
    local error_count=0
    local success_dbs=""
    local error_dbs=""
    local deleted_backups_json="[]"

    for db in "${!BACKUP_RESULTS[@]}"; do
        if [ "${BACKUP_RESULTS[$db]}" = "success" ]; then
            success_count=$((success_count+1))
            success_dbs="$success_dbs\"$db\","
        else
            error_count=$((error_count+1))
            error_dbs="$error_dbs\"$db\","
        fi
    done

    success_dbs=${success_dbs%,}
    error_dbs=${error_dbs%,}

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

###############################################################################
# Limpeza da instalação
###############################################################################
cleanup_old_installation() {
    echo_info "Removendo instalação anterior..."
    rm -f "$SCRIPT_DIR/pg_backup_manager.sh"
    rm -f "$SCRIPT_DIR/pg_backup"
    rm -f "$SCRIPT_DIR/pg_restore_db"
    rm -f "$ENV_FILE"
    rm -f /etc/pg_backup.env
    rm -f "$HOME/.pg_backup.env"
    rm -rf /var/backups/postgres /var/log/pg_backup
    echo_success "Instalação antiga removida com sucesso."
}

###############################################################################
# Função de backup completo/parcial
###############################################################################
do_backup_databases() {
    rotate_logs
    verify_container "$CONTAINER_NAME"
    test_database_connection

    local mode="$1" # full ou partial
    local selected_databases=()

    if [ "$mode" = "full" ]; then
        echo_info "Realizando backup completo..."
        local databases
        databases=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" | tr -d ' \t')
        selected_databases=($databases)
    else
        echo_info "Selecione os bancos de dados para backup:"
        local databases
        databases=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;")
        local db_array=($databases)
        local count=1
        for db in "${db_array[@]}"; do
            echo "$count) $db"
            count=$((count+1))
        done
        echo "Digite os números dos bancos de dados separados por espaço (ou 'all' para todos):"
        read -r db_numbers
        if [ "$db_numbers" = "all" ]; then
            selected_databases=("${db_array[@]}")
        else
            IFS=' ' read -r -a db_indexes <<< "$db_numbers"
            for index in "${db_indexes[@]}"; do
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -le "${#db_array[@]}" ]; then
                    selected_databases+=("${db_array[$((index-1))]}")
                else
                    echo_error "Índice inválido: $index"
                    exit 1
                fi
            done
        fi
    fi

    local TIMESTAMP=$(date +%Y%m%d%H%M%S)
    local success_count=0
    local error_count=0

    for db in "${selected_databases[@]}"; do
        ensure_backup_possible "$db" || { BACKUP_RESULTS[$db]="error"; error_count=$((error_count+1)); continue; }

        local BACKUP_FILENAME="postgres_backup_${TIMESTAMP}_${db}.sql"
        local BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"

        echo_info "Fazendo backup do banco '$db'..."
        if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            pg_dump -U "$PG_USER" -F p --inserts -v "$db" > "$BACKUP_PATH" 2>>"$LOG_FILE"; then

            gzip -f "$BACKUP_PATH"
            BACKUP_PATH="${BACKUP_PATH}.gz"

            local BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
            echo_success "Backup concluído: $(basename "$BACKUP_PATH") (Tamanho: $BACKUP_SIZE)"

            BACKUP_RESULTS[$db]="success"
            BACKUP_SIZES[$db]="$BACKUP_SIZE"
            BACKUP_FILES[$db]="$(basename "$BACKUP_PATH")"
            success_count=$((success_count+1))

            # Deletar backups antigos
            local old_backup
            old_backup=$(find "$BACKUP_DIR" -name "postgres_backup_*_${db}.sql.gz" -mtime +"$RETENTION_DAYS" -print | sort | head -n1 || true)
            if [ -n "$old_backup" ]; then
                DELETED_BACKUPS[$db]="$(basename "$old_backup")"
                rm -f "$old_backup"
                echo_info "Backup antigo deletado: $(basename "$old_backup")"
            fi
            find "$BACKUP_DIR" -name "postgres_backup_*_${db}.sql.gz" -mtime +"$RETENTION_DAYS" -delete

        else
            echo_error "Falha no backup de $db"
            BACKUP_RESULTS[$db]="error"
            error_count=$((error_count+1))
        fi
    done

    # Enviar webhook detalhado
    # Você pode personalizar a mensagem dependendo se é full ou partial
    local action_text
    local status_text
    local total_count=${#selected_databases[@]}
    if [ "$error_count" -eq 0 ]; then
        status_text="OK"
    else
        status_text="PARTIAL_ERROR"
    fi

    if [ "$mode" = "full" ]; then
        action_text="Backup completo realizado"
    else
        action_text="Backup parcial realizado"
    fi

    local success_list=""
    local error_list=""
    for db in "${!BACKUP_RESULTS[@]}"; do
        if [ "${BACKUP_RESULTS[$db]}" = "success" ]; then
            success_list="$success_list\"$db\","
        else
            error_list="$error_list\"$db\","
        fi
    done
    success_list=${success_list%,}
    error_list=${error_list%,}

    local deleted_backups_json="["
    for db in "${!DELETED_BACKUPS[@]}"; do
        deleted_backups_json="$deleted_backups_json{\"database\":\"$db\",\"file\":\"${DELETED_BACKUPS[$db]}\",\"reason\":\"Prazo de retenção expirado\"},"
    done
    deleted_backups_json=${deleted_backups_json%,}"]"

    local payload="{
        \"action\": \"$action_text\",
        \"date\": \"$(date '+%d/%m/%Y %H:%M:%S')\",
        \"summary\": {
            \"total_databases\": $total_count,
            \"successful_backups\": $success_count,
            \"failed_backups\": $error_count,
            \"successful_databases\": [$success_list],
            \"failed_databases\": [$error_list]
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
        \"status\": \"$status_text\",
        \"notes\": \"$action_text em $(date). $success_count de $total_count bancos backupeados com sucesso.\"
    }"

    send_webhook "$payload"
}

###############################################################################
# Função para restauração completa ou parcial
###############################################################################
do_restore_databases() {
    rotate_logs
    verify_container "$CONTAINER_NAME"
    test_database_connection

    local mode="$1" # full ou partial
    local available_backups=($(find "$BACKUP_DIR" -type f -name "postgres_backup_*.sql.gz" | sort -r))
    if [ ${#available_backups[@]} -eq 0 ]; then
        echo_error "Nenhum backup encontrado para restauração."
        return 1
    fi

    # Obter lista de bancos disponíveis a partir dos backups
    declare -A LATEST_BACKUPS
    for backup_file in "${available_backups[@]}"; do
        local db_name
        db_name=$(basename "$backup_file" | sed -E 's/postgres_backup_[0-9]+_(.*)\.sql\.gz/\1/')
        # Vamos considerar o mais recente backup para cada db
        if [ -z "${LATEST_BACKUPS[$db_name]+x}" ]; then
            LATEST_BACKUPS[$db_name]="$backup_file"
        fi
    done

    local selected_databases=()

    if [ "$mode" = "full" ]; then
        echo_info "Restauração completa: todos os bancos encontrados serão restaurados."
        selected_databases=("${!LATEST_BACKUPS[@]}")
    else
        echo_info "Selecione os bancos de dados para restauração (com base nos backups disponíveis):"
        local db_list=("${!LATEST_BACKUPS[@]}")
        local count=1
        for db in "${db_list[@]}"; do
            echo "$count) $db"
            count=$((count+1))
        done
        echo "Digite os números dos bancos de dados separados por espaço (ou 'all' para todos):"
        read -r db_numbers
        if [ "$db_numbers" = "all" ]; then
            selected_databases=("${db_list[@]}")
        else
            IFS=' ' read -r -a db_indexes <<< "$db_numbers"
            for index in "${db_indexes[@]}"; do
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -le "${#db_list[@]}" ]; then
                    selected_databases+=("${db_list[$((index-1))]}")
                else
                    echo_error "Índice inválido: $index"
                    exit 1
                fi
            done
        fi
    fi

    local success_count=0
    local error_count=0

    for db in "${selected_databases[@]}"; do
        local BACKUP="${LATEST_BACKUPS[$db]}"
        echo_warning "ATENÇÃO: Isso irá substituir o banco '$db' existente!"
        echo_info "Restaurando backup para o banco '$db' a partir de $(basename "$BACKUP")"
        create_database_if_not_exists "$db"

        echo_info "Descomprimindo backup..."
        gunzip -c "$BACKUP" > "$BACKUP_DIR/temp_restore.sql"

        analyze_and_recreate_structures "$db" "$BACKUP_DIR/temp_restore.sql"

        # Dropar conexões existentes
        docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -d "$db" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();" >/dev/null 2>&1

        local progress_file="$TEMP_DIR/progress"
        local operation_file="$TEMP_DIR/operation"
        echo "0" > "$progress_file"
        echo "" > "$operation_file"

        local modified_sql="$TEMP_DIR/modified_restore.sql"
        prepare_sql_with_progress "$BACKUP_DIR/temp_restore.sql" "$modified_sql" "$progress_file" "$operation_file"

        local total_operations
        total_operations=$(grep -c '\\!' "$modified_sql" || echo "0")
        total_operations=$((total_operations + 1))
        echo_info "Total de operações: $total_operations"

        (
            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                psql -U "$PG_USER" -d "$db" -f "/var/backups/postgres/modified_restore.sql" > /dev/null 2>>"$LOG_FILE"
        ) &
        local psql_pid=$!

        while kill -0 "$psql_pid" 2>/dev/null; do
            local current
            current=$(cat "$progress_file" 2>/dev/null || echo "0")
            local current_operation
            current_operation=$(cat "$operation_file" 2>/dev/null || echo "")
            show_progress "$current" "$total_operations" "$current_operation"
            sleep 0.1
        done
        wait "$psql_pid"
        local restore_status=$?
        echo

        rm -f "$BACKUP_DIR/temp_restore.sql" "$progress_file" "$operation_file" "$modified_sql"

        if [ "$restore_status" -eq 0 ]; then
            echo_success "Restauração do banco '$db' concluída com sucesso."
            BACKUP_RESULTS[$db]="success"
            success_count=$((success_count+1))
        else
            echo_error "Falha na restauração do banco '$db'."
            BACKUP_RESULTS[$db]="error"
            error_count=$((error_count+1))
        fi
    done

    local action_text
    local status_text
    local total_count=${#selected_databases[@]}
    if [ "$error_count" -eq 0 ]; then
        status_text="OK"
    else
        status_text="PARTIAL_ERROR"
    fi

    if [ "$mode" = "full" ]; then
        action_text="Restauração completa realizada"
    else
        action_text="Restauração parcial realizada"
    fi

    local success_list=""
    local error_list=""
    for db in "${selected_databases[@]}"; do
        if [ "${BACKUP_RESULTS[$db]}" = "success" ]; then
            success_list="$success_list\"$db\","
        else
            error_list="$error_list\"$db\","
        fi
    done
    success_list=${success_list%,}
    error_list=${error_list%,}

    local payload="{
        \"action\": \"$action_text\",
        \"date\": \"$(date '+%d/%m/%Y %H:%M:%S')\",
        \"summary\": {
            \"total_databases\": $total_count,
            \"successful_restores\": $success_count,
            \"failed_restores\": $error_count,
            \"successful_databases\": [$success_list],
            \"failed_databases\": [$error_list]
        },
        \"status\": \"$status_text\",
        \"notes\": \"$action_text em $(date). $success_count de $total_count bancos restaurados com sucesso.\"
    }"

    send_webhook "$payload"
}

###############################################################################
# Criar links simbólicos
###############################################################################
create_symlinks() {
    echo_info "Criando links simbólicos..."
    ln -sf "$SCRIPT_DIR/pg_backup_manager.sh" "$SCRIPT_DIR/pg_backup"
    ln -sf "$SCRIPT_DIR/pg_backup_manager.sh" "$SCRIPT_DIR/pg_restore_db"

    if [ ! -L "$SCRIPT_DIR/pg_backup" ] || [ ! -L "$SCRIPT_DIR/pg_restore_db" ]; then
        echo_error "Falha ao criar links simbólicos."
        exit 1
    fi

    echo_success "Links simbólicos criados com sucesso:"
    echo "  - pg_backup      -> $SCRIPT_DIR/pg_backup_manager.sh"
    echo "  - pg_restore_db  -> $SCRIPT_DIR/pg_backup_manager.sh"
}

###############################################################################
# Configurar cron job
###############################################################################
configure_cron() {
    echo_info "Configurando cron job para backup diário às 00:00..."
    if ! crontab -l 2>/dev/null | grep -q "/usr/local/bin/pg_backup"; then
        (crontab -l 2>/dev/null; echo "0 0 * * * /usr/local/bin/pg_backup") | crontab -
        echo_success "Cron job configurado com sucesso."
    else
        echo_info "Cron job já está configurado."
    fi
}

###############################################################################
# Instalar o script principal
###############################################################################
install_script() {
    echo_info "Instalando PostgreSQL Backup Manager..."
    cp "$0" "$SCRIPT_DIR/pg_backup_manager.sh"
    chmod +x "$SCRIPT_DIR/pg_backup_manager.sh"
    echo_success "Script principal instalado em $SCRIPT_DIR/pg_backup_manager.sh"
    create_symlinks
    configure_cron
    echo_success "Instalação concluída com sucesso!"
}

###############################################################################
# Atualizar o script principal
###############################################################################
update_script() {
    echo_info "Atualizando script principal..."
    local latest_script_url="https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/pg_backup_manager.sh"
    if curl -sSL "$latest_script_url" -o "$SCRIPT_DIR/pg_backup_manager.sh"; then
        chmod +x "$SCRIPT_DIR/pg_backup_manager.sh"
        echo_success "Script principal atualizado com sucesso."
    else
        echo_error "Falha ao atualizar o script principal. Verifique sua conexão."
        exit 1
    fi
    echo_info "Atualização dos links simbólicos..."
    create_symlinks
    echo_success "Atualização concluída com sucesso!"
}

###############################################################################
# Mostrar Menu Interativo
###############################################################################
show_menu() {
    while true; do
        echo
        echo "===== PostgreSQL Backup Manager ====="
        echo "1. Fazer backup completo"
        echo "2. Fazer backup de bancos específicos"
        echo "3. Restaurar backup completo"
        echo "4. Restaurar backup de bancos específicos"
        echo "5. Atualizar configurações"
        echo "6. Sair"
        read -p "Digite o número da opção desejada: " choice

        case $choice in
            1)
                do_backup_databases "full"
                ;;
            2)
                do_backup_databases "partial"
                ;;
            3)
                do_restore_databases "full"
                ;;
            4)
                do_restore_databases "partial"
                ;;
            5)
                setup_config
                ;;
            6)
                echo_info "Saindo..."
                exit 0
                ;;
            *)
                echo_warning "Opção inválida. Tente novamente."
                ;;
        esac
    done
}

###############################################################################
# Função principal
###############################################################################
main() {
    case "${1:-}" in
        "--backup")
            if [ ! -f "$ENV_FILE" ]; then
                echo_error "Arquivo de configuração '$ENV_FILE' não encontrado. Execute o script sem argumentos para configurar."
                exit 1
            fi
            source "$ENV_FILE"
            verify_container "$CONTAINER_NAME"
            do_backup_databases "full"
            ;;
        "--restore")
            if [ ! -f "$ENV_FILE" ]; then
                echo_error "Arquivo de configuração '$ENV_FILE' não encontrado. Execute o script sem argumentos para configurar."
                exit 1
            fi
            source "$ENV_FILE"
            verify_container "$CONTAINER_NAME"
            do_restore_databases "full"
            ;;
        "--clean")
            cleanup_old_installation
            ;;
        "--install")
            install_script
            ;;
        "--update")
            update_script
            ;;
        "--configure")
            setup_config
            ;;
        *)
            # Se não for via link, executar configuração inicial se necessário
            if [ ! -f "$ENV_FILE" ]; then
                echo_info "Iniciando configuração do PostgreSQL Backup Manager..."
                setup_config
                echo_success "Configuração concluída com sucesso!"
            else
                source "$ENV_FILE"
                verify_container "$CONTAINER_NAME"
            fi
            show_menu
            ;;
    esac
}

main "$@"
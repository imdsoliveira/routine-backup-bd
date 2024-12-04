#!/bin/bash

# =============================================================================
# PostgreSQL Backup Manager 2024
# Versão: 1.4.4
# =============================================================================
# - Backup automático diário
# - Retenção configurável
# - Notificações webhook consolidadas
# - Restauração interativa com barra de progresso
# - Detecção automática de container PostgreSQL
# - Criação automática de estruturas (sequências, tabelas e índices)
# - Gerenciamento de logs com rotação
# - Recriação automática de estruturas ausentes
# - Verificação pré-backup para garantir a existência do banco de dados
# - Correção na ordem das operações durante a restauração
# - Função de limpeza para remover instalações anteriores
# =============================================================================

set -e
set -u
set -o pipefail

# Configurações Globais
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="/root/.pg_backup.env"
LOG_FILE="/var/log/pg_backup.log"
MAX_LOG_SIZE=$((50 * 1024 * 1024)) # 50MB
BACKUP_DIR="/var/backups/postgres"
TEMP_DIR="$BACKUP_DIR/temp"

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
    echo -e "\e[34m[INFO]\e[0m $1" | tee -a "$LOG_FILE" >/dev/null 2>&1 || echo -e "\e[34m[INFO]\e[0m $1"
}

function echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1" | tee -a "$LOG_FILE" >/dev/null 2>&1 || echo -e "\e[32m[SUCCESS]\e[0m $1"
}

function echo_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1" | tee -a "$LOG_FILE" >/dev/null 2>&1 || echo -e "\e[33m[WARNING]\e[0m $1"
}

function echo_error() {
    echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOG_FILE" >/dev/null 2>&1 || echo -e "\e[31m[ERROR]\e[0m $1"
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
    local CONFIG_EXISTS=false
    local TEMP_ENV_FILE="/tmp/pg_backup.env.tmp"

    # Verificar configuração existente em múltiplos locais
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
        echo "----------------------------------------"
        
        read -p "Deseja atualizar alguma configuração? (yes/no): " update_config
        if [[ "$update_config" =~ ^(yes|y|Y) ]]; then
            source "$ENV_FILE"
            
            echo_info "Para cada configuração, pressione Enter para manter o valor atual"
            echo_info "ou digite um novo valor para atualizar."
            
            # Container
            read -p "Container PostgreSQL [$CONTAINER_NAME]: " new_container
            CONTAINER_NAME=${new_container:-$CONTAINER_NAME}
            
            # Usuário
            read -p "Usuário PostgreSQL [$PG_USER]: " new_user
            PG_USER=${new_user:-$PG_USER}
            
            # Senha (sempre pedir para maior segurança e exibir na tela)
            read -p "Senha PostgreSQL (Enter para manter atual): " new_password
            if [ -n "$new_password" ]; then
                read -p "Confirme a senha: " confirm_password
                if [ "$new_password" = "$confirm_password" ]; then
                    PG_PASSWORD="$new_password"
                else
                    echo_error "As senhas não coincidem. Mantendo senha atual."
                fi
            fi
            
            # Retenção
            read -p "Dias de retenção dos backups [$RETENTION_DAYS]: " new_retention
            RETENTION_DAYS=${new_retention:-$RETENTION_DAYS}
            
            # Webhook
            read -p "URL do Webhook [$WEBHOOK_URL]: " new_webhook
            WEBHOOK_URL=${new_webhook:-$WEBHOOK_URL}
        else
            echo_info "Mantendo configurações existentes."
            return 0
        fi
    else
        echo_info "Configurando novo backup..."
        
        # Detectar container
        CONTAINER_NAME=$(detect_postgres_container)
        
        # Usuário PostgreSQL
        read -p "Usuário PostgreSQL [postgres]: " PG_USER
        PG_USER=${PG_USER:-postgres}
        
        # Senha PostgreSQL (visível)
        read -p "Senha PostgreSQL: " PG_PASSWORD
        read -p "Confirme a senha: " PG_PASSWORD_CONFIRM
        while [ "$PG_PASSWORD" != "$PG_PASSWORD_CONFIRM" ]; do
            echo_warning "As senhas não coincidem. Tente novamente."
            read -p "Senha PostgreSQL: " PG_PASSWORD
            read -p "Confirme a senha: " PG_PASSWORD_CONFIRM
        done
        
        # Retenção
        read -p "Dias de retenção dos backups [30]: " RETENTION_DAYS
        RETENTION_DAYS=${RETENTION_DAYS:-30}
        
        # Webhook
        read -p "URL do Webhook: " WEBHOOK_URL
    fi

    # Salvar configurações em múltiplos locais com redundância
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

    # Salvar em múltiplos locais com permissões apropriadas
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
    
    echo_success "Configurações salvas com redundância em:"
    echo "  - $ENV_FILE"
    [ -f "/etc/pg_backup.env" ] && echo "  - /etc/pg_backup.env"
    echo "  - $HOME/.pg_backup.env"

    # Limpar arquivo temporário
    [ -f "$TEMP_ENV_FILE" ] && rm -f "$TEMP_ENV_FILE"
}

# Função para verificar e atualizar container PostgreSQL
function verify_container() {
    local current_container="$1"
    
    # Verificar se o container atual ainda existe e está rodando
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

# Função para verificar se o backup é possível (verificar existência do banco)
function ensure_backup_possible() {
    local db="$1"
    if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -lqt | cut -d \| -f 1 | grep -qw "$db"; then
        echo_error "Banco de dados '$db' não existe"
        return 1
    fi
    return 0
}

# Função para criar banco de dados se não existir (usada na restauração)
function create_database_if_not_exists() {
    local db_name="$1"
    ensure_database_exists "$db_name"
}

# Função para analisar e recriar estruturas ausentes
function analyze_and_recreate_structures() {
    local DB="$1"
    local BACKUP_FILE="$2"
    echo_info "Analisando estruturas do banco '$DB'..."

    # Extrair apenas as estruturas (CREATE SEQUENCE, CREATE TABLE, CREATE INDEX, etc.)
    local SEQUENCES_FILE="$TEMP_DIR/sequences.sql"
    local TABLES_FILE="$TEMP_DIR/tables.sql"
    local INDEXES_FILE="$TEMP_DIR/indexes.sql"

    grep -E '^CREATE SEQUENCE' "$BACKUP_FILE" > "$SEQUENCES_FILE"
    grep -E '^CREATE TABLE' "$BACKUP_FILE" > "$TABLES_FILE"
    grep -E '^CREATE INDEX' "$BACKUP_FILE" > "$INDEXES_FILE"

    # Processar na ordem correta: sequences, tabelas, índices
    for file in "$SEQUENCES_FILE" "$TABLES_FILE" "$INDEXES_FILE"; do
        [ -f "$file" ] || continue
        while IFS= read -r create_stmt; do
            if [[ "$create_stmt" =~ ^CREATE[[:space:]]+(SEQUENCE|TABLE|INDEX)[[:space:]]+\"?([^\"]+)\"?[[:space:]]* ]]; then
                local structure_type="${BASH_REMATCH[1]}"
                local structure_name="${BASH_REMATCH[2]}"
                echo_info "Verificando $structure_type \"$structure_name\"..."

                case "$structure_type" in
                    SEQUENCE)
                        # Verificar se a sequência existe
                        if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                            psql -U "$PG_USER" -d "$DB" -c "\ds \"$structure_name\"" &>/dev/null; then
                            echo_info "Criando sequência \"$structure_name\"..."
                            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                                psql -U "$PG_USER" -d "$DB" -c "$create_stmt"
                        fi
                        ;;
                    TABLE)
                        # Verificar se a tabela existe
                        if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                            psql -U "$PG_USER" -d "$DB" -c "\d \"$structure_name\"" &>/dev/null; then
                            echo_info "Criando tabela \"$structure_name\"..."
                            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                                psql -U "$PG_USER" -d "$DB" -c "$create_stmt"
                        fi
                        ;;
                    INDEX)
                        # Verificar se o índice existe
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

    # Limpar arquivos temporários
    rm -f "$SEQUENCES_FILE" "$TABLES_FILE" "$INDEXES_FILE"
}

# Função para mostrar barra de progresso com operação atual
function show_progress() {
    local current=$1
    local total=$2
    local operation="$3"
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))

    printf "\r\033[K" # Limpar linha atual
    printf "Progresso: ["
    printf "%${filled}s" '' | tr ' ' '#'
    printf "%${empty}s" '' | tr ' ' '-'
    printf "] %3d%%" "$percentage"
    if [ -n "$operation" ]; then
        printf " %s" "$operation"
    fi
}

# Função para preparar arquivo SQL com rastreamento de progresso
function prepare_sql_with_progress() {
    local input_file="$1"
    local output_file="$2"
    local progress_file="$3"
    local operation_file="$4"

    awk -v progress_file="$progress_file" -v operation_file="$operation_file" '
    /^(SET|CREATE|ALTER|COPY|INSERT)/ {
        # Extrair descrição da operação
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
        
        # Escapar possíveis aspas na operação
        gsub(/"/, "\\\"", operation)
        
        print $0;
        print "\\! (echo $(($(cat \"" progress_file "\")) + 1) > \"" progress_file "\"; echo \"" operation "\" > \"" operation_file "\");"
    }
    !/^(SET|CREATE|ALTER|COPY|INSERT)/ {
        print $0;
    }
    ' "$input_file" > "$output_file"
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

# Função para limpar instalação anterior
function cleanup_old_installation() {
    echo_info "Removendo instalação anterior..."
    rm -f /usr/local/bin/pg_backup_manager.sh
    rm -f /usr/local/bin/pg_backup
    rm -f /usr/local/bin/pg_restore_db
    rm -f "$ENV_FILE"
    echo_success "Limpeza concluída"
}

# Função principal de backup
function do_backup() {
    rotate_logs
    local TIMESTAMP=$(date +%Y%m%d%H%M%S)
    local databases

    echo_info "Iniciando backup completo..."

    # Lista todos os bancos
    databases=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" | tr -d ' \t\n')

    for db in $databases; do
        ensure_backup_possible "$db" || continue

        local BACKUP_FILENAME="postgres_backup_${TIMESTAMP}_${db}.sql"
        local BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"

        echo_info "Fazendo backup do banco '$db'..."

        if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            pg_dump -U "$PG_USER" -F p --inserts -v "$db" > "$BACKUP_PATH" 2>>"$LOG_FILE"; then

            # Comprimir backup
            gzip -f "$BACKUP_PATH"
            BACKUP_PATH="${BACKUP_PATH}.gz"

            local BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
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

    # Primeiro selecionar o backup
    echo_info "Backups disponíveis:"
    mapfile -t BACKUPS < <(find "$BACKUP_DIR" -type f -name "postgres_backup_*.sql.gz" -print | sort -r)

    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo_error "Nenhum backup encontrado"
        return 1
    fi

    # Mostrar backups disponíveis
    for i in "${!BACKUPS[@]}"; do
        local file_size
        file_size=$(du -h "${BACKUPS[$i]}" | cut -f1)
        local file_date
        file_date=$(stat -c %y "${BACKUPS[$i]}" | cut -d. -f1)
        echo "$((i+1))) $(basename "${BACKUPS[$i]}") (Tamanho: $file_size, Data: $file_date)"
    done

    # Selecionar backup
    while true; do
        read -p "Digite o número do backup (ou 0 para cancelar): " selection
        if [ "$selection" = "0" ]; then
            echo_info "Restauração cancelada."
            return 0
        elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -le "${#BACKUPS[@]}" ]; then
            BACKUP="${BACKUPS[$((selection-1))]}"
            break
        fi
        echo_warning "Seleção inválida."
    done

    # Extrair nome do banco do arquivo de backup
    local DB
    DB=$(basename "$BACKUP" | sed -E 's/postgres_backup_[0-9]+_(.*)\.sql\.gz/\1/')

    echo_warning "ATENÇÃO: Isso irá substituir o banco '$DB' existente!"
    read -p "Digite 'sim' para confirmar: " CONFIRM
    if [ "$CONFIRM" != "sim" ]; then
        echo_info "Restauração cancelada."
        return 0
    fi

    echo_info "Restaurando backup '$BACKUP' em '$DB'..."

    # Verificar e atualizar container se necessário
    verify_container "$CONTAINER_NAME"

    # Criar banco se não existir
    echo_info "Verificando banco de dados '$DB'..."
    if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -lqt | cut -d \| -f 1 | grep -qw "$DB"; then
        echo_info "Criando banco de dados '$DB'..."
        if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -c "CREATE DATABASE \"$DB\" WITH TEMPLATE template0;" 2>>"$LOG_FILE"; then
            echo_error "Falha ao criar banco de dados '$DB'"
            return 1
        fi
        echo_success "Banco de dados criado com sucesso"
    fi

    # Verificar se o banco foi criado
    if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -lqt | cut -d \| -f 1 | grep -qw "$DB"; then
        echo_error "Não foi possível criar o banco de dados '$DB'"
        return 1
    fi

    # Descomprimir backup
    echo_info "Descomprimindo backup..."
    gunzip -c "$BACKUP" > "$BACKUP_DIR/temp_restore.sql"

    # Corrigir sintaxe SQL
    echo_info "Corrigindo sintaxe SQL..."
    sed -i 's/CREATE TABLE \([^(]*\)(/CREATE TABLE \1 ();/g' "$BACKUP_DIR/temp_restore.sql"
    sed -i 's/^);$/ALTER TABLE/g' "$BACKUP_DIR/temp_restore.sql"

    # Criar arquivos temporários para progresso
    local progress_file="$TEMP_DIR/progress"
    local operation_file="$TEMP_DIR/operation"
    echo "0" > "$progress_file"
    echo "" > "$operation_file"

    # Preparar SQL com progresso
    local modified_sql="$TEMP_DIR/modified_restore.sql"
    prepare_sql_with_progress "$BACKUP_DIR/temp_restore.sql" "$modified_sql" "$progress_file" "$operation_file"

    # Analisar e recriar estruturas ausentes
    analyze_and_recreate_structures "$DB" "$modified_sql"

    # Dropar conexões existentes
    docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB' AND pid <> pg_backend_pid();" >/dev/null 2>&1

    # Contar operações
    local total_operations
    total_operations=$(grep -c '\\!' "$modified_sql" || echo "0")
    total_operations=$((total_operations + 1))
    echo_info "Total de operações: $total_operations"

    # Restaurar com barra de progresso
    (
        docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -d "$DB" -f "/var/backups/postgres/modified_restore.sql" > /dev/null 2>>"$LOG_FILE"
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
    echo # Nova linha após barra de progresso

    # Limpar
    rm -f "$BACKUP_DIR/temp_restore.sql" "$progress_file" "$operation_file" "$modified_sql"

    if [ "$restore_status" -eq 0 ]; then
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
}

# Função para limpar instalação anterior
function cleanup_old_installation() {
    echo_info "Removendo instalação anterior..."
    rm -f /usr/local/bin/pg_backup_manager.sh
    rm -f /usr/local/bin/pg_backup
    rm -f /usr/local/bin/pg_restore_db
    rm -f "$ENV_FILE"
    echo_success "Limpeza concluída"
}

# Função principal
function main() {
    case "${1:-}" in
        "--backup"|"--restore")
            if [ ! -f "$ENV_FILE" ]; then
                echo_error "Arquivo de configuração '$ENV_FILE' não encontrado. Execute o script sem argumentos para configurar."
                exit 1
            fi
            source "$ENV_FILE"
            verify_container "$CONTAINER_NAME"
            if [ "${1:-}" = "--backup" ]; then
                do_backup
            else
                do_restore
            fi
            ;;
        "--clean")
            cleanup_old_installation
            ;;
        *)
            # Verificar se está sendo executado via link simbólico
            local script_name
            script_name=$(basename "$0")
            case "$script_name" in
                pg_backup)
                    action="--backup"
                    ;;
                pg_restore_db)
                    action="--restore"
                    ;;
                *)
                    action=""
                    ;;
            esac

            if [ -n "$action" ]; then
                # Executar backup ou restore diretamente
                main "$action"
                exit 0
            fi

            # Limpar instalação anterior primeiro
            cleanup_old_installation

            # Configuração inicial
            setup_config

            # Criar links simbólicos (já feitos no script de instalação)

            # Configurar cron para backup diário às 00:00 (já feito no script de instalação)

            echo_success "Configuração concluída com sucesso!"
            echo_info "Comandos disponíveis:"
            echo "  Backup manual: pg_backup"
            echo "  Restauração: pg_restore_db"
            echo "  Limpar instalação: pg_backup_manager.sh --clean"

            # Solicitar execução imediata do backup, se desejado
            read -p "Deseja executar um backup agora? (yes/no): " do_backup_now
            if [[ "$do_backup_now" =~ ^(yes|y|Y) ]]; then
                do_backup
            fi
            ;;
    esac
}

main "$@"
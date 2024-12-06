#!/bin/bash

# =============================================================================
# PostgreSQL Backup Manager Simplificado 2024
# Versão: 2.0.1
# =============================================================================
# Funcionalidades:
# - Detecção automática de contêiner PostgreSQL
# - Backup completo ou parcial
# - Retenção configurável de backups
# - Notificações via Webhook
# - Restauração interativa de backups
# - Configuração via arquivo .env com opção de atualização
# - Logs coloridos e detalhados no terminal
# - Automatização de backups diários com cron
# =============================================================================

set -euo pipefail

# =============================================================================
# Variáveis Globais
# =============================================================================
SCRIPT_DIR="/usr/local/bin"
ENV_FILE="/root/.pg_backup.env"
LOG_FILE="/var/log/pg_backup.log"
BACKUP_DIR="/var/backups/postgres"
TEMP_DIR="$BACKUP_DIR/temp"
MAX_LOG_SIZE=$((50 * 1024 * 1024)) # 50MB

# Cores para saída no terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem cor

# Declarar arrays associativos para armazenar resultados
declare -A BACKUP_RESULTS
declare -A BACKUP_SIZES
declare -A BACKUP_FILES
declare -A DELETED_BACKUPS

# =============================================================================
# Funções de Log
# =============================================================================
echo_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE" >/dev/null 2>&1 || echo -e "${BLUE}[INFO]${NC} $1"
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

# =============================================================================
# Rotação de Logs
# =============================================================================
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

# =============================================================================
# Detecção Automática do Contêiner PostgreSQL
# =============================================================================
detect_postgres_container() {
    local containers
    containers=$(docker ps --format "{{.Names}}" | grep -i postgres || true)
    if [ -z "$containers" ]; then
        echo_error "Nenhum contêiner PostgreSQL encontrado!"
        exit 1
    elif [ "$(echo "$containers" | wc -l)" -eq 1 ]; then
        echo "$containers"
    else
        echo_info "Contêineres PostgreSQL disponíveis:"
        echo "$containers"
        while true; do
            read -p "Digite o nome do contêiner PostgreSQL: " container_name
            if docker ps --format "{{.Names}}" | grep -qw "$container_name"; then
                echo "$container_name"
                break
            else
                echo_warning "Nome do contêiner inválido. Tente novamente."
            fi
        done
    fi
}

# =============================================================================
# Envio de Webhook
# =============================================================================
send_webhook() {
    local payload="$1"
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL")
        if [[ "$http_code" =~ ^2 ]]; then
            return 0
        fi
        retry=$((retry + 1))
        echo_warning "Falha ao enviar webhook. Tentativa $retry de $max_retries."
        sleep 5
    done

    echo_error "Falha ao enviar webhook após $max_retries tentativas."
    return 1
}

# =============================================================================
# Configuração do Ambiente (.env)
# =============================================================================
setup_config() {
    local config_exists=false

    # Verificar se o arquivo .env já existe
    if [ -f "$ENV_FILE" ]; then
        config_exists=true
        echo_info "Configurações existentes encontradas em: $ENV_FILE"
        echo "Configurações atuais:"
        echo "----------------------------------------"
        grep -v "PG_PASSWORD" "$ENV_FILE" | sed 's/^/  /'
        echo "  PG_PASSWORD=******"
        echo "----------------------------------------"
        read -p "Deseja manter estas configurações? (yes/no): " keep_config
        if [[ "$keep_config" =~ ^(yes|y|Y)$ ]]; then
            source "$ENV_FILE"
            return 0
        fi
    fi

    echo_info "Configurando novo backup..."

    # Detectar contêiner PostgreSQL
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
        if [[ ! "$confirm" =~ ^(yes|y|Y)$ ]]; then
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

# =============================================================================
# Verificação da Conexão com o Banco de Dados
# =============================================================================
test_database_connection() {
    echo_info "Testando conexão com o banco de dados..."
    if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -c "SELECT 1;" >/dev/null 2>&1; then
        echo_error "Falha na conexão com o banco de dados. Verifique as configurações."
        exit 1
    fi
    echo_success "Conexão com o banco de dados estabelecida com sucesso."
}

# =============================================================================
# Verificação e Atualização do Contêiner
# =============================================================================
verify_container() {
    local current_container="$1"
    if ! docker ps --format "{{.Names}}" | grep -qw "^${current_container}$"; then
        echo_warning "Contêiner '$current_container' não encontrado ou não está rodando."
        echo_info "Detectando contêiner PostgreSQL novamente..."
        local new_container
        new_container=$(detect_postgres_container)
        if [ "$new_container" != "$current_container" ]; then
            echo_info "Atualizando contêiner para: $new_container"
            sed -i "s/CONTAINER_NAME=\".*\"/CONTAINER_NAME=\"$new_container\"/" "$ENV_FILE"
            CONTAINER_NAME="$new_container"
        fi
    fi
}

# =============================================================================
# Garantir que o Banco de Dados Existe
# =============================================================================
ensure_database_exists() {
    local db_name="$1"
    if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
        echo_info "Criando banco de dados '$db_name'..."
        docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -c "CREATE DATABASE \"$db_name\" WITH TEMPLATE template0;"
    fi
}

# =============================================================================
# Função de Backup Completo ou Parcial
# =============================================================================
do_backup() {
    local mode="$1" # "full" ou "partial"
    rotate_logs
    verify_container "$CONTAINER_NAME"
    test_database_connection

    local selected_databases=()

    if [ "$mode" == "full" ]; then
        echo_info "Iniciando backup completo..."
        selected_databases=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" | tr -d ' \t')
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
        if [ "$db_numbers" == "all" ]; then
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
        echo_info "Iniciando backup parcial..."
    fi

    local TIMESTAMP=$(date +%Y%m%d%H%M%S)

    for db in ${selected_databases[@]}; do
        ensure_database_exists "$db"

        echo_info "Fazendo backup do banco '$db'..."
        local BACKUP_FILENAME="postgres_backup_${TIMESTAMP}_${db}.sql"
        local BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"

        if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            pg_dump -U "$PG_USER" -F p --inserts -v "$db" > "$BACKUP_PATH" 2>>"$LOG_FILE"; then

            gzip -f "$BACKUP_PATH"
            BACKUP_PATH="${BACKUP_PATH}.gz"

            local BACKUP_SIZE
            BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
            echo_success "Backup completo do banco '$db': $(basename "$BACKUP_PATH") (Tamanho: $BACKUP_SIZE)"

            BACKUP_RESULTS["$db"]="success"
            BACKUP_SIZES["$db"]="$BACKUP_SIZE"
            BACKUP_FILES["$db"]="$(basename "$BACKUP_PATH")"

            # Remover backups antigos
            local old_backup
            old_backup=$(find "$BACKUP_DIR" -name "postgres_backup_*_${db}.sql.gz" -mtime +"$RETENTION_DAYS" -print | sort | head -n1 || true)
            if [ -n "$old_backup" ]; then
                DELETED_BACKUPS["$db"]="$(basename "$old_backup")"
                rm -f "$old_backup"
                echo_info "Backup antigo deletado: $(basename "$old_backup")"
            fi
            find "$BACKUP_DIR" -name "postgres_backup_*_${db}.sql.gz" -mtime +"$RETENTION_DAYS" -delete

        else
            echo_error "Falha no backup do banco '$db'"
            BACKUP_RESULTS["$db"]="error"
        fi
    done

    # Construir payload para webhook
    local payload='{
      "action": "Backup realizado",
      "date": "'$(date '+%d/%m/%Y %H:%M:%S')'",
      "backup_details": ['
    
    local first=1
    for db in "${!BACKUP_RESULTS[@]}"; do
        if [ "$first" -eq 1 ]; then
            first=0
        else
            payload+=', '
        fi
        if [ "${BACKUP_RESULTS[$db]}" == "success" ]; then
            payload+='{
          "database_name": "'$db'",
          "backup_file": "'${BACKUP_FILES[$db]}'",
          "backup_size": "'${BACKUP_SIZES[$db]}'"
        }'
        else
            payload+='{
          "database_name": "'$db'",
          "status": "error",
          "message": "Falha no backup."
        }'
        fi
    done

    payload+='], "retention_days": '$RETENTION_DAYS', "deleted_backups": ['
    
    first=1
    for db in "${!DELETED_BACKUPS[@]}"; do
        if [ "$first" -eq 1 ]; then
            first=0
        else
            payload+=', '
        fi
        payload+='{
          "database_name": "'$db'",
          "backup_name": "'${DELETED_BACKUPS[$db]}'",
          "deletion_reason": "Prazo de retenção expirado"
        }'
    done

    payload+='], "status": "'$(if [ "${#BACKUP_RESULTS[@]}" -eq 0 ]; then echo "OK"; else echo "COMPLETED"; fi)'", "notes": "Backup executado conforme cron job configurado." }'

    # Enviar webhook
    send_webhook "$payload"
}

# =============================================================================
# Função de Restauração
# =============================================================================
do_restore() {
    rotate_logs
    verify_container "$CONTAINER_NAME"
    test_database_connection

    echo_info "Selecione o tipo de restauração:"
    echo "1) Restauração completa (todas as bases)"
    echo "2) Restauração de bancos específicos"
    echo "3) Cancelar"
    read -p "Digite o número da opção desejada: " restore_option

    case "$restore_option" in
        1)
            restore_full
            ;;
        2)
            restore_partial
            ;;
        3)
            echo_info "Restauração cancelada."
            exit 0
            ;;
        *)
            echo_warning "Opção inválida. Cancelando restauração."
            exit 1
            ;;
    esac
}

restore_full() {
    echo_info "Iniciando restauração completa..."
    local unique_databases=()

    # Extrair nomes únicos de bancos de dados
    for backup in "${all_backups[@]}"; do
        local db_name
        db_name=$(basename "$backup" | sed -E 's/postgres_backup_[0-9]+_(.*)\.sql\.gz/\1/')
        unique_databases+=("$db_name")
    done

    # Remover duplicatas
    IFS=$'\n' unique_databases=($(sort -u <<<"${unique_databases[*]}"))
    unset IFS

    for db in "${unique_databases[@]}"; do
        restore_database "$db"
    done
}

restore_partial() {
    echo_info "Selecione os bancos de dados para restauração:"
    local db_list=()
    for backup in "${all_backups[@]}"; do
        local db_name
        db_name=$(basename "$backup" | sed -E 's/postgres_backup_[0-9]+_(.*)\.sql\.gz/\1/')
        db_list+=("$db_name")
    done

    # Remover duplicatas
    IFS=$'\n' db_list=($(sort -u <<<"${db_list[*]}"))
    unset IFS

    local count=1
    for db in "${db_list[@]}"; do
        echo "$count) $db"
        count=$((count+1))
    done

    echo "Digite os números dos bancos de dados separados por espaço (ou 'all' para todos):"
    read -r db_numbers
    local selected_databases=()

    if [ "$db_numbers" == "all" ]; then
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

    for db in "${selected_databases[@]}"; do
        restore_database "$db"
    done
}

restore_database() {
    local db="$1"
    echo_info "Restaurando banco '$db'..."

    # Listar backups disponíveis para o banco
    mapfile -t db_backups < <(find "$BACKUP_DIR" -type f -name "postgres_backup_*_${db}.sql.gz" | sort -r)

    if [ ${#db_backups[@]} -eq 0 ]; then
        echo_error "Nenhum backup encontrado para o banco '$db'."
        return 1
    fi

    echo_info "Backups disponíveis para '$db':"
    local count=1
    for bkp in "${db_backups[@]}"; do
        local file_size
        file_size=$(du -h "$bkp" | cut -f1)
        local file_date
        file_date=$(date -r "$bkp" '+%d/%m/%Y %H:%M:%S')
        echo "$count) $(basename "$bkp") (Tamanho: $file_size, Data: $file_date)"
        count=$((count+1))
    done

    local selection
    while true; do
        read -p "Digite o número do backup (ou 0 para cancelar): " selection
        if [ "$selection" == "0" ]; then
            echo_info "Restauração do banco '$db' cancelada pelo usuário."
            return 1
        elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -le "${#db_backups[@]}" ]; then
            local chosen_backup="${db_backups[$((selection-1))]}"
            break
        else
            echo_warning "Seleção inválida. Tente novamente."
        fi
    done

    echo_warning "ATENÇÃO: Isso irá substituir o banco '$db' existente!"
    read -p "Digite 'sim' para confirmar: " confirm
    if [ "$confirm" != "sim" ]; then
        echo_info "Restauração do banco '$db' cancelada pelo usuário."
        return 1
    fi

    # Criar o banco se não existir
    ensure_database_exists "$db"

    # Descomprimir o backup
    gunzip -c "$chosen_backup" > "$TEMP_DIR/temp_restore.sql"

    # Terminar conexões existentes
    docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -d "$db" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();" >/dev/null 2>&1

    # Restaurar dados
    if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -d "$db" -f "/var/backups/postgres/temp/temp_restore.sql" 2>>"$LOG_FILE"; then
        echo_success "Restauração do banco '$db' concluída com sucesso."
        # Enviar webhook de sucesso
        send_webhook "{
  \"action\": \"Restauração realizada com sucesso\",
  \"date\": \"$(date '+%d/%m/%Y %H:%M:%S')\",
  \"database_name\": \"$db\",
  \"backup_file\": \"$(basename "$chosen_backup")\",
  \"status\": \"OK\",
  \"notes\": \"Restauração executada conforme solicitação do usuário.\"
}"
    else
        echo_error "Falha na restauração do banco '$db'."
        # Enviar webhook de erro
        send_webhook "{
  \"action\": \"Restauração falhou\",
  \"date\": \"$(date '+%d/%m/%Y %H:%M:%S')\",
  \"database_name\": \"$db\",
  \"backup_file\": \"$(basename "$chosen_backup")\",
  \"status\": \"ERROR\",
  \"notes\": \"Falha na execução da restauração.\"
}"
    fi

    # Limpar arquivos temporários
    rm -f "$TEMP_DIR/temp_restore.sql"
}

# =============================================================================
# Listar Todos os Backups
# =============================================================================
list_all_backups() {
    echo_info "Listando todos os backups disponíveis:"
    mapfile -t all_backups < <(find "$BACKUP_DIR" -type f -name "postgres_backup_*.sql.gz" | sort -r)
    if [ ${#all_backups[@]} -eq 0 ]; then
        echo_warning "Nenhum backup encontrado."
        return
    fi

    local count=1
    for bkp in "${all_backups[@]}"; do
        local file_size
        file_size=$(du -h "$bkp" | cut -f1)
        local file_date
        file_date=$(date -r "$bkp" '+%d/%m/%Y %H:%M:%S')
        echo_info "$count) $(basename "$bkp") (Tamanho: $file_size, Data: $file_date)"
        count=$((count+1))
    done
}

# =============================================================================
# Menu Interativo
# =============================================================================
show_menu() {
    while true; do
        echo
        echo "===== PostgreSQL Backup Manager v1.0.1 ====="
        echo "1. Fazer backup completo"
        echo "2. Fazer backup de bancos específicos"
        echo "3. Restaurar backup"
        echo "4. Listar todos os backups"
        echo "5. Atualizar configurações"
        echo "6. Sair"
        read -p "Digite o número da opção desejada: " choice

        case $choice in
            1)
                do_backup "full"
                ;;
            2)
                do_backup "partial"
                ;;
            3)
                do_restore
                ;;
            4)
                list_all_backups
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

# =============================================================================
# Instalação do Script Principal
# =============================================================================
install_script() {
    echo_info "Instalando PostgreSQL Backup Manager..."
    cp "$0" "$SCRIPT_DIR/pg_backup_manager.sh"
    chmod +x "$SCRIPT_DIR/pg_backup_manager.sh"
    echo_success "Script principal instalado em $SCRIPT_DIR/pg_backup_manager.sh"

    # Criar links simbólicos
    ln -sf "$SCRIPT_DIR/pg_backup_manager.sh" "$SCRIPT_DIR/pg_backup"
    ln -sf "$SCRIPT_DIR/pg_backup_manager.sh" "$SCRIPT_DIR/pg_restore_db"

    if [ ! -L "$SCRIPT_DIR/pg_backup" ] || [ ! -L "$SCRIPT_DIR/pg_restore_db" ]; then
        echo_error "Falha ao criar links simbólicos."
        exit 1
    fi

    echo_success "Links simbólicos criados com sucesso:"
    echo "  - pg_backup      -> $SCRIPT_DIR/pg_backup_manager.sh"
    echo "  - pg_restore_db  -> $SCRIPT_DIR/pg_backup_manager.sh"

    # Configurar cron job
    configure_cron
    echo_success "Instalação concluída com sucesso!"
}

# =============================================================================
# Configurar Cron Job para Backup Diário às 00:00
# =============================================================================
configure_cron() {
    echo_info "Configurando cron job para backup diário às 00:00..."
    if ! crontab -l 2>/dev/null | grep -q "/usr/local/bin/pg_backup_manager.sh --backup"; then
        (crontab -l 2>/dev/null; echo "0 0 * * * /usr/local/bin/pg_backup_manager.sh --backup") | crontab -
        echo_success "Cron job configurado com sucesso."
    else
        echo_info "Cron job já está configurado."
    fi
}

# =============================================================================
# Atualização do Script Principal
# =============================================================================
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
    ln -sf "$SCRIPT_DIR/pg_backup_manager.sh" "$SCRIPT_DIR/pg_backup"
    ln -sf "$SCRIPT_DIR/pg_backup_manager.sh" "$SCRIPT_DIR/pg_restore_db"
    echo_success "Atualização concluída com sucesso!"
}

# =============================================================================
# Função de Limpeza da Instalação
# =============================================================================
clean_installation() {
    echo_info "Limpando instalação anterior..."
    rm -f "$SCRIPT_DIR/pg_backup_manager.sh"
    rm -f "$SCRIPT_DIR/pg_backup"
    rm -f "$SCRIPT_DIR/pg_restore_db"
    rm -f "$ENV_FILE"
    rm -f /etc/pg_backup.env
    rm -rf "$BACKUP_DIR" /var/log/pg_backup.log
    crontab -l 2>/dev/null | grep -v "/usr/local/bin/pg_backup_manager.sh --backup" | crontab -
    echo_success "Instalação antiga removida com sucesso."
}

# =============================================================================
# Função Principal
# =============================================================================
main() {
    case "${1:-}" in
        "--backup")
            if [ ! -f "$ENV_FILE" ]; then
                echo_error "Arquivo de configuração '$ENV_FILE' não encontrado. Execute o script sem argumentos para configurar."
                exit 1
            fi
            source "$ENV_FILE"
            verify_container "$CONTAINER_NAME"
            do_backup "full"
            ;;
        "--restore")
            if [ ! -f "$ENV_FILE" ]; then
                echo_error "Arquivo de configuração '$ENV_FILE' não encontrado. Execute o script sem argumentos para configurar."
                exit 1
            fi
            source "$ENV_FILE"
            verify_container "$CONTAINER_NAME"
            do_restore
            ;;
        "--install")
            install_script
            ;;
        "--update")
            update_script
            ;;
        "--clean")
            clean_installation
            ;;
        *)
            if [ ! -f "$ENV_FILE" ]; then
                echo_info "Iniciando configuração do PostgreSQL Backup Manager..."
                setup_config
                echo_success "Configuração concluída com sucesso!"
                install_script
            fi
            source "$ENV_FILE"
            verify_container "$CONTAINER_NAME"
            show_menu
            ;;
    esac
}

main "$@"
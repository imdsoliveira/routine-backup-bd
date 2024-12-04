#!/bin/bash

# =============================================================================
# PostgreSQL Backup Manager 2024
# =============================================================================
# - Backup automático diário
# - Retenção configurável
# - Notificações webhook
# - Restauração interativa
# - Detecção automática de container
# =============================================================================

set -e
set -u
set -o pipefail

# Configurações Globais
readonly ENV_FILE="/root/.pg_backup.env"
readonly LOG_FILE="/var/log/pg_backup.log"
readonly BACKUP_DIR="/var/backups/postgres"

# Criar diretórios necessários
mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
chmod 700 "$BACKUP_DIR"

# Funções de Utilidade
function echo_info() { echo -e "\e[34m[INFO]\e[0m $1" | tee -a "$LOG_FILE"; }
function echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1" | tee -a "$LOG_FILE"; }
function echo_warning() { echo -e "\e[33m[WARNING]\e[0m $1" | tee -a "$LOG_FILE"; }
function echo_error() { echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOG_FILE"; }

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
        echo "Containers PostgreSQL disponíveis:"
        echo "$containers"
        read -p "Digite o nome do container: " container_name
        echo "$container_name"
    fi
}

# Função para enviar webhook
function send_webhook() {
    local payload="$1"
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        if curl -s -S -X POST -H "Content-Type: application/json" \
            -d "$payload" "$WEBHOOK_URL" -o /dev/null -w "%{http_code}" | grep -q "^2"; then
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
    
    read -p "Senha PostgreSQL: " PG_PASSWORD
    if [ -z "$PG_PASSWORD" ]; then
        echo_error "Senha não pode estar vazia"
        exit 1
    fi
    
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
EOF
    chmod 600 "$ENV_FILE"
    echo_success "Configurações salvas em $ENV_FILE"
}

# Função principal de backup
function do_backup() {
    local timestamp=$(date +%Y%m%d%H%M%S)
    local databases
    
    echo_info "Iniciando backup completo..."
    
    # Lista todos os bancos
    databases=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;")
    
    for db in $databases; do
        local backup_file="postgres_backup_${timestamp}_${db}.sql"
        local backup_path="$BACKUP_DIR/$backup_file"
        
        echo_info "Fazendo backup do banco $db..."
        
        if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            pg_dump -U "$PG_USER" -F p "$db" > "$backup_path"; then
            
            # Comprimir backup
            gzip "$backup_path"
            local backup_size=$(ls -lh "${backup_path}.gz" | awk '{print $5}')
            
            # Pegar informações do backup mais antigo que será deletado
            local old_backup=$(find "$BACKUP_DIR" -name "postgres_backup_*_${db}.sql.gz" -mtime +"$RETENTION_DAYS" -print | sort | head -n1)
            local delete_info="{}"
            if [ ! -z "$old_backup" ]; then
                delete_info="{\"backup_name\":\"$(basename "$old_backup")\",\"deletion_reason\":\"Prazo de retenção expirado\"}"
            fi
            
            # Enviar webhook
            send_webhook "{
                \"action\": \"Backup realizado com sucesso\",
                \"date\": \"$(date '+%d/%m/%Y %H:%M:%S')\",
                \"database_name\": \"$db\",
                \"backup_file\": \"${backup_file}.gz\",
                \"backup_size\": \"$backup_size\",
                \"retention_days\": $RETENTION_DAYS,
                \"deleted_backup\": $delete_info,
                \"status\": \"OK\",
                \"notes\": \"Backup executado com sucesso\"
            }"
            
            # Limpar backups antigos
            find "$BACKUP_DIR" -name "postgres_backup_*_${db}.sql.gz" -mtime +"$RETENTION_DAYS" -delete
            
            echo_success "Backup de $db concluído (Tamanho: $backup_size)"
        else
            echo_error "Falha no backup de $db"
            send_webhook "{
                \"action\": \"Backup falhou\",
                \"date\": \"$(date '+%d/%m/%Y %H:%M:%S')\",
                \"database_name\": \"$db\",
                \"status\": \"ERROR\",
                \"notes\": \"Falha na execução do backup\"
            }"
        fi
    done
}

# Função principal de restauração
function do_restore() {
    echo_info "Backups disponíveis:"
    
    local backups=()
    while IFS= read -r file; do
        backups+=("$file")
    done < <(find "$BACKUP_DIR" -name "postgres_backup_*.sql.gz" -print0 | xargs -0 ls -t)
    
    if [ ${#backups[@]} -eq 0 ]; then
        echo_error "Nenhum backup encontrado em $BACKUP_DIR"
        return 1
    fi
    
    echo "Selecione o backup para restaurar:"
    for i in "${!backups[@]}"; do
        local file_size=$(ls -lh "${backups[$i]}" | awk '{print $5}')
        local file_date=$(ls -l "${backups[$i]}" | awk '{print $6, $7, $8}')
        echo "$((i+1))) $(basename "${backups[$i]}") (Tamanho: $file_size, Data: $file_date)"
    done
    
    read -p "Digite o número do backup (ou 0 para cancelar): " selection
    if [ "$selection" = "0" ] || [ -z "$selection" ]; then
        echo_info "Restauração cancelada"
        return 0
    fi
    
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -gt "${#backups[@]}" ]; then
        echo_error "Seleção inválida"
        return 1
    fi
    
    local selected_backup="${backups[$((selection-1))]}"
    local db_name=$(basename "$selected_backup" | sed -E 's/postgres_backup_[0-9]+_(.*)\.sql\.gz/\1/')
    
    echo_warning "ATENÇÃO: Isso irá substituir o banco '$db_name' existente!"
    read -p "Digite 'sim' para confirmar: " confirm
    if [ "$confirm" != "sim" ]; then
        echo_info "Restauração cancelada"
        return 0
    fi
    
    echo_info "Restaurando $db_name..."
    
    # Descomprimir backup
    gunzip -c "$selected_backup" > "$BACKUP_DIR/temp_restore.sql"
    
    # Dropar conexões existentes
    docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db_name'"
    
    # Restaurar
    if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -d "$db_name" -f "/var/backups/postgres/temp_restore.sql"; then
        echo_success "Restauração concluída com sucesso"
        send_webhook "{
            \"action\": \"Restauração realizada com sucesso\",
            \"date\": \"$(date '+%d/%m/%Y %H:%M:%S')\",
            \"database_name\": \"$db_name\",
            \"backup_file\": \"$(basename "$selected_backup")\",
            \"status\": \"OK\"
        }"
    else
        echo_error "Falha na restauração"
        send_webhook "{
            \"action\": \"Restauração falhou\",
            \"date\": \"$(date '+%d/%m/%Y %H:%M:%S')\",
            \"database_name\": \"$db_name\",
            \"status\": \"ERROR\"
        }"
    fi
    
    rm -f "$BACKUP_DIR/temp_restore.sql"
}

# Função principal
function main() {
    case "${1:-}" in
        "--backup")
            source "$ENV_FILE"
            do_backup
            ;;
        "--restore")
            source "$ENV_FILE"
            do_restore
            ;;
        *)
            # Configuração inicial
            setup_config
            
            # Criar scripts de backup/restore
            echo_info "Configurando scripts..."
            
            # Script de backup
            cat > /usr/local/bin/pg_backup <<EOF
#!/bin/bash
source "$ENV_FILE"
$(declare -f echo_info echo_success echo_warning echo_error send_webhook do_backup)
do_backup
EOF
            chmod +x /usr/local/bin/pg_backup
            
            # Script de restore
            cat > /usr/local/bin/pg_restore_db <<EOF
#!/bin/bash
source "$ENV_FILE"
$(declare -f echo_info echo_success echo_warning echo_error send_webhook do_restore)
do_restore
EOF
            chmod +x /usr/local/bin/pg_restore_db
            
            # Configurar cron
            (crontab -l 2>/dev/null | grep -v pg_backup; echo "0 0 * * * /usr/local/bin/pg_backup") | crontab -
            
            echo_success "Configuração concluída!"
            echo_info "Comandos disponíveis:"
            echo "  Backup manual: pg_backup"
            echo "  Restauração: pg_restore_db"
            
            read -p "Executar backup agora? (yes/no): " do_backup
            if [[ "$do_backup" =~ ^(yes|y|Y) ]]; then
                do_backup
            fi
            ;;
    esac
}

main "$@"
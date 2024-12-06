#!/bin/bash

# Script para configurar rotina de backup automática do PostgreSQL em servidores Dockerizados
set -e

# Funções de utilidade
function echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; sleep 1; }
function echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; sleep 1; }
function echo_warning() { echo -e "\e[33m[WARNING]\e[0m $1"; sleep 1; }
function echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; sleep 1; }
function command_exists() { command -v "$1" >/dev/null 2>&1; }
function valid_url() { [[ "$1" =~ ^https?://.+ ]]; }

# Função para enviar webhook
function send_webhook() {
    local payload="$1"
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL"
}

ENV_FILE="/root/.backup_postgres.env"

# Função para carregar variáveis do arquivo .env
load_env() {
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
save_env() {
    cat > "$ENV_FILE" <<EOF
PG_USER="$PG_USER"
PG_PASSWORD="$PG_PASSWORD"
RETENTION_DAYS="$RETENTION_DAYS"
WEBHOOK_URL="$WEBHOOK_URL"
BACKUP_OPTION="$BACKUP_OPTION"
CONTAINER_NAME="$CONTAINER_NAME"
BACKUP_DIR="/var/backups/postgres"
EOF
    chmod 600 "$ENV_FILE"
    echo_success "Configurações salvas em $ENV_FILE"
}

# Função principal de backup
do_backup() {
    local DB="$1"
    local TIMESTAMP=$(date +%Y%m%d%H%M%S)
    local BACKUP_FILENAME="postgres_backup_${TIMESTAMP}_${DB}.backup"
    local BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"
    
    echo_info "Iniciando backup do banco '$DB'..."
    
    case "$BACKUP_OPTION" in
        1)
            echo_info "Realizando backup completo com inserts..."
            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                pg_dump -U "$PG_USER" -F p --inserts "$DB" > "$BACKUP_PATH"
            ;;
        2)
            echo_info "Realizando backup apenas das tabelas..."
            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
                pg_dump -U "$PG_USER" -F c --schema-only "$DB" > "$BACKUP_PATH"
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
                pg_dump -U "$PG_USER" $TABLE_ARGS --inserts "$DB" > "$BACKUP_PATH"
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        local BACKUP_SIZE=$(ls -lh "$BACKUP_PATH" | awk '{print $5}')
        echo_success "Backup concluído: $BACKUP_FILENAME (Tamanho: $BACKUP_SIZE)"
        send_webhook "{\"status\":\"success\",\"database\":\"$DB\",\"file\":\"$BACKUP_FILENAME\",\"size\":\"$BACKUP_SIZE\"}"
    else
        echo_error "Falha no backup de $DB"
        send_webhook "{\"status\":\"error\",\"database\":\"$DB\",\"file\":\"$BACKUP_FILENAME\"}"
        return 1
    fi
}

# Função principal de restauração
do_restore() {
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
    local BACKUPS=($(ls -1 "$BACKUP_DIR" | grep "_${DB}.backup\$"))
    
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo_error "Nenhum backup encontrado para $DB"
        return 1
    fi
    
    select BACKUP in "${BACKUPS[@]}" "Cancelar"; do
        if [ "$BACKUP" = "Cancelar" ]; then
            return 0
        elif [ -n "$BACKUP" ]; then
            break
        fi
        echo "Seleção inválida"
    done
    
    read -p "Confirma a restauração? ISSO SUBSTITUIRÁ O BANCO ATUAL (yes/no): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^(yes|Yes|YES)$ ]]; then
        return 0
    fi
    
    echo_info "Restaurando $BACKUP em $DB..."
    if [[ "$BACKUP" =~ .*\.backup$ ]]; then
        docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -d "$DB" -f "/var/backups/postgres/$BACKUP"
    else
        docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            pg_restore -U "$PG_USER" -d "$DB" -c "/var/backups/postgres/$BACKUP"
    fi
    
    if [ $? -eq 0 ]; then
        echo_success "Restauração concluída com sucesso"
        send_webhook "{\"status\":\"success\",\"action\":\"restore\",\"database\":\"$DB\",\"file\":\"$BACKUP\"}"
    else
        echo_error "Falha na restauração"
        send_webhook "{\"status\":\"error\",\"action\":\"restore\",\"database\":\"$DB\",\"file\":\"$BACKUP\"}"
    fi
}

# Script principal
main() {
    echo_info "Iniciando processo de configuração..."
    
    if ! load_env; then
        if ! command_exists docker; then
            echo_error "Docker não está instalado."
            exit 1
        fi
        
        echo_info "Identificando containers PostgreSQL..."
        POSTGRES_CONTAINERS=$(docker ps --format "{{.Names}}" | grep -i postgres)
        
        if [ -z "$POSTGRES_CONTAINERS" ]; then
            echo_error "Nenhum container PostgreSQL encontrado"
            exit 1
        fi
        
        if [ $(echo "$POSTGRES_CONTAINERS" | wc -l) -eq 1 ]; then
            CONTAINER_NAME="$POSTGRES_CONTAINERS"
            echo_info "Container identificado: $CONTAINER_NAME"
        else
            echo "Containers disponíveis:"
            echo "$POSTGRES_CONTAINERS"
            read -p "Nome do container: " CONTAINER_NAME
            if ! echo "$POSTGRES_CONTAINERS" | grep -q "^$CONTAINER_NAME\$"; then
                echo_error "Container inválido"
                exit 1
            fi
        fi
        
        read -p "Usar usuário padrão 'postgres'? (yes/no): " USE_DEFAULT
        if [[ "$USE_DEFAULT" =~ ^(yes|Yes|YES)$ ]]; then
            PG_USER="postgres"
        else
            read -p "Usuário PostgreSQL: " PG_USER
        fi
        
        read -p "Senha PostgreSQL: " PG_PASSWORD
        read -p "Retenção em dias [30]: " RETENTION_DAYS
        RETENTION_DAYS=${RETENTION_DAYS:-30}
        
        while true; do
            read -p "URL do Webhook: " WEBHOOK_URL
            if valid_url "$WEBHOOK_URL"; then break; fi
            echo_error "URL inválida"
        done
        
        echo_info "Tipos de backup:"
        echo "1) Completo com inserts"
        echo "2) Apenas estrutura"
        echo "3) Tabelas específicas"
        read -p "Selecione [1]: " BACKUP_OPTION
        BACKUP_OPTION=${BACKUP_OPTION:-1}
        
        save_env
    fi
    
    # Criar diretório de backup
    BACKUP_DIR=${BACKUP_DIR:-"/var/backups/postgres"}
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    
    # Criar scripts
    BACKUP_SCRIPT="/usr/local/bin/backup_postgres.sh"
    RESTORE_SCRIPT="/usr/local/bin/restore_postgres.sh"
    
    # Script de backup
    cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
source "$ENV_FILE"
$(declare -f echo_info echo_success echo_warning echo_error send_webhook do_backup)
for DB in \$(docker exec -e PGPASSWORD="\$PG_PASSWORD" "\$CONTAINER_NAME" psql -U "\$PG_USER" -tAc "SELECT datname FROM pg_database WHERE datistemplate = false;"); do
    do_backup "\$DB"
done
find "\$BACKUP_DIR" -type f -mtime +\$RETENTION_DAYS -delete
EOF
    chmod +x "$BACKUP_SCRIPT"
    
    # Script de restauração
    cat > "$RESTORE_SCRIPT" <<EOF
#!/bin/bash
source "$ENV_FILE"
$(declare -f echo_info echo_success echo_warning echo_error send_webhook do_restore)
do_restore
EOF
    chmod +x "$RESTORE_SCRIPT"
    
    # Configurar cron
    (crontab -l 2>/dev/null | grep -v backup_postgres.sh; echo "0 0 * * * $BACKUP_SCRIPT") | crontab -
    
    echo_success "Configuração concluída!"
    echo_info "Comandos disponíveis:"
    echo "  Backup: $BACKUP_SCRIPT"
    echo "  Restauração: $RESTORE_SCRIPT"
    
    read -p "Executar backup agora? (yes/no): " DO_BACKUP
    if [[ "$DO_BACKUP" =~ ^(yes|Yes|YES)$ ]]; then
        "$BACKUP_SCRIPT"
    fi
}

main "$@"

#!/bin/bash

# =============================================================================
# PostgreSQL Backup Manager 2024
# Versão: 1.4.5
# =============================================================================
# - Backup automático diário
# - Retenção configurável
# - Notificações webhook consolidadas 
# - Restauração interativa com barra de progresso
# - Detecção automática de container PostgreSQL
# - Criação automática de estruturas
# - Gerenciamento de logs com rotação
# - Recriação automática de estruturas ausentes
# - Verificação pré-backup
# - Correção na ordem das operações
# =============================================================================

set -e
set -u
set -o pipefail

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configurações Globais
SCRIPT_DIR="/usr/local/bin"
ENV_FILE="/root/.pg_backup.env"
LOG_FILE="/var/log/pg_backup.log"
BACKUP_DIR="/var/backups/postgres"
TEMP_DIR="$BACKUP_DIR/temp"
MAX_LOG_SIZE=$((50 * 1024 * 1024))

# Criar diretórios necessários
mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR" "$TEMP_DIR" || true
touch "$LOG_FILE" || true
chmod 644 "$LOG_FILE" || true
chmod 700 "$BACKUP_DIR" "$TEMP_DIR" || true

# Estrutura para resultados
declare -A BACKUP_RESULTS
declare -A BACKUP_SIZES 
declare -A BACKUP_FILES
declare -A DELETED_BACKUPS

# Funções de log
echo_info() { echo -e "${YELLOW}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
echo_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; }

# Rotação de logs
rotate_logs() {
    if [ -f "$LOG_FILE" ]; then
        local size=$(stat -c%s "$LOG_FILE")
        if [ "$size" -ge "$MAX_LOG_SIZE" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.$(date '+%Y%m%d%H%M%S').bak"
            touch "$LOG_FILE"
            chmod 644 "$LOG_FILE"
            echo_info "Log rotacionado"
        fi
    fi
}

# Detectar container PostgreSQL
detect_postgres_container() {
    local containers=$(docker ps --format "{{.Names}}" | grep -i postgres)
    if [ -z "$containers" ]; then
        echo_error "Nenhum container PostgreSQL encontrado!"
        exit 1
    fi
    if [ "$(echo "$containers" | wc -l)" -eq 1 ]; then
        echo "$containers"
        return
    fi
    
    echo_info "Containers PostgreSQL disponíveis:"
    echo "$containers"
    while true; do
        read -p "Digite o nome do container: " container_name
        if docker ps --format "{{.Names}}" | grep -qw "$container_name"; then
            echo "$container_name"
            break
        fi
        echo_info "Container inválido, tente novamente"
    done
}

# Verificar container
verify_container() {
    local current="$1"
    if ! docker ps --format "{{.Names}}" | grep -qw "^${current}$"; then
        echo_info "Container '$current' não encontrado, detectando novo..."
        local new=$(detect_postgres_container)
        if [ "$new" != "$current" ]; then
            echo_info "Atualizando container para: $new"
            sed -i "s/CONTAINER_NAME=\".*\"/CONTAINER_NAME=\"$new\"/" "$ENV_FILE"
            CONTAINER_NAME="$new"
        fi
    fi
}

# Setup inicial
setup_config() {
    if [ -f "$ENV_FILE" ]; then
        echo_info "Configurações existentes encontradas:"
        cat "$ENV_FILE"
        read -p "Deseja manter? (yes/no): " keep
        if [[ "$keep" =~ ^(yes|y|Y) ]]; then
            source "$ENV_FILE"
            return 0
        fi
    fi

    echo_info "Configurando backup..."
    
    CONTAINER_NAME=$(detect_postgres_container)
    
    read -p "Usuário PostgreSQL [postgres]: " PG_USER
    PG_USER=${PG_USER:-postgres}
    
    read -p "Senha PostgreSQL: " PG_PASSWORD
    read -p "Confirme a senha: " PG_PASSWORD_CONFIRM
    
    while [ "$PG_PASSWORD" != "$PG_PASSWORD_CONFIRM" ]; do
        echo_info "Senhas não coincidem, tente novamente"
        read -p "Senha PostgreSQL: " PG_PASSWORD
        read -p "Confirme a senha: " PG_PASSWORD_CONFIRM
    done

    read -p "Dias de retenção [30]: " RETENTION_DAYS
    RETENTION_DAYS=${RETENTION_DAYS:-30}
    
    read -p "URL do Webhook: " WEBHOOK_URL
    
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

    # Backup redundante
    if [ -w /etc ]; then
        cp "$ENV_FILE" "/etc/pg_backup.env"
        chmod 600 "/etc/pg_backup.env"
    fi
    cp "$ENV_FILE" "$HOME/.pg_backup.env"
    chmod 600 "$HOME/.pg_backup.env"

    echo_success "Configurações salvas com redundância em:"
    echo "  - $ENV_FILE"
    [ -f "/etc/pg_backup.env" ] && echo "  - /etc/pg_backup.env"
    echo "  - $HOME/.pg_backup.env"
}

# Enviar webhook
send_webhook() {
    local payload="$1"
    local retries=3
    local try=0

    while [ $try -lt $retries ]; do
        if curl -s -S -H "Content-Type: application/json" \
            -d "$payload" "$WEBHOOK_URL" -w "%{http_code}" -o /dev/null | grep -q "^2"; then
            return 0
        fi
        try=$((try + 1))
        [ $try -lt $retries ] && sleep 5
    done

    echo_error "Falha no webhook após $retries tentativas"
    return 1
}

# Verificar banco
ensure_database_exists() {
    local db="$1"
    if ! docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -lqt | cut -d \| -f 1 | grep -qw "$db"; then
        echo_info "Criando banco '$db'..."
        docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$PG_USER" -c "CREATE DATABASE \"$db\" WITH TEMPLATE template0;"
    fi
}

# Backup principal 
do_backup() {
    rotate_logs
    verify_container "$CONTAINER_NAME"
    
    echo_info "Iniciando backup..."
    local timestamp=$(date +%Y%m%d%H%M%S)
    
    local databases=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

    for db in $databases; do
        local filename="postgres_backup_${timestamp}_${db}.sql"
        local filepath="$BACKUP_DIR/$filename"
        
        echo_info "Backup de '$db'..."
        
        if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
            pg_dump -U "$PG_USER" -F p "$db" > "$filepath"; then
            
            gzip -f "$filepath"
            filepath="${filepath}.gz"
            
            local size=$(du -h "$filepath" | cut -f1)
            echo_success "Backup concluído: $(basename "$filepath") ($size)"
            
            BACKUP_RESULTS[$db]="success"
            BACKUP_SIZES[$db]="$size"
            BACKUP_FILES[$db]="$(basename "$filepath")"
            
            # Limpar backups antigos
            find "$BACKUP_DIR" -name "postgres_backup_*_${db}.sql.gz" \
                -mtime +"$RETENTION_DAYS" -delete
            
        else
            echo_error "Falha no backup de $db"
            BACKUP_RESULTS[$db]="error"
        fi
    done
    
    send_consolidated_webhook
}

# Restauração principal
do_restore() {
    rotate_logs
    verify_container "$CONTAINER_NAME"
    
    # Listar backups
    echo_info "Backups disponíveis:"
    mapfile -t BACKUPS < <(find "$BACKUP_DIR" -name "postgres_backup_*.sql.gz" -print | sort -r)
    
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo_error "Nenhum backup encontrado"
        return 1
    fi

    # Mostrar backups 
    for i in "${!BACKUPS[@]}"; do
        local size=$(du -h "${BACKUPS[$i]}" | cut -f1)
        local date=$(stat -c %y "${BACKUPS[$i]}" | cut -d. -f1)
        echo "$((i+1))) $(basename "${BACKUPS[$i]}") ($size, $date)"
    done

    # Selecionar backup
    while true; do
        read -p "Selecione o backup (0 para cancelar): " sel
        if [ "$sel" = "0" ]; then
            echo_info "Restauração cancelada"
            return 0
        fi
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -le "${#BACKUPS[@]}" ]; then
            BACKUP="${BACKUPS[$((sel-1))]}"
            break
        fi
        echo_info "Seleção inválida"
    done

    # Extrair nome do banco
    local DB=$(basename "$BACKUP" | sed -E 's/postgres_backup_[0-9]+_(.*)\.sql\.gz/\1/')
    
    echo_info "ATENÇÃO: Isso substituirá o banco '$DB'"
    read -p "Digite 'sim' para confirmar: " confirm
    if [ "$confirm" != "sim" ]; then
        echo_info "Restauração cancelada"
        return 0
    fi

    # Criar banco
    ensure_database_exists "$DB"

    # Descomprimir e restaurar
    echo_info "Restaurando backup..."
    gunzip -c "$BACKUP" > "$BACKUP_DIR/temp_restore.sql"
    
    if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -d "$DB" -f "/var/backups/postgres/temp_restore.sql"; then
        echo_success "Restauração concluída"
        send_webhook "{
            \"action\": \"Restauração realizada\",
            \"database\": \"$DB\",
            \"backup\": \"$(basename "$BACKUP")\",
            \"status\": \"OK\"
        }"
    else
        echo_error "Falha na restauração"
        send_webhook "{
            \"action\": \"Restauração falhou\",
            \"database\": \"$DB\",
            \"backup\": \"$(basename "$BACKUP")\",
            \"status\": \"ERROR\"
        }"
    fi
    
    rm -f "$BACKUP_DIR/temp_restore.sql"
}

# Função principal
main() {
    case "${1:-}" in
        "--backup")
            [ ! -f "$ENV_FILE" ] && echo_error "Execute sem argumentos para configurar" && exit 1
            source "$ENV_FILE"
            do_backup
            ;;
        "--restore")  
            [ ! -f "$ENV_FILE" ] && echo_error "Execute sem argumentos para configurar" && exit 1
            source "$ENV_FILE"
            do_restore
            ;;
        *)
            setup_config
            
            # Links simbólicos
            echo_info "Criando links..."
            ln -sf "$SCRIPT_DIR/pg_backup_manager.sh" "$SCRIPT_DIR/pg_backup"
            ln -sf "$SCRIPT_DIR/pg_backup_manager.sh" "$SCRIPT_DIR/pg_restore_db"
            
            # Cron diário
            (crontab -l 2>/dev/null | grep -v 'pg_backup'; echo "0 0 * * * $SCRIPT_DIR/pg_backup") | crontab -
            
            echo_success "Configuração concluída!"
            echo_info "Comandos:"
            echo "  pg_backup        : Backup manual"
            echo "  pg_restore_db    : Restauração"
            
            read -p "Executar backup agora? (y/n): " do_now
            [[ "$do_now" =~ ^[yY] ]] && do_backup
            ;;
    esac
}

main "$@"
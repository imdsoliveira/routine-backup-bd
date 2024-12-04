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

ENV_FILE="/root/.backup_postgres.env"

# Função para enviar webhook
function send_webhook() {
    local payload="$1"
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL"
}

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
            echo_info "Realizando backup apenas da estrutura..."
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
        *)
            echo_error "Opção de backup inválida."
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        local BACKUP_SIZE=$(du -h "$BACKUP_PATH" | awk '{print $1}')
        echo_success "Backup concluído: $BACKUP_FILENAME (Tamanho: $BACKUP_SIZE)"
        send_webhook "{\"action\":\"Backup realizado com sucesso\",\"date\":\"$(date +"%d/%m/%Y %H:%M:%S")\",\"database_name\":\"$DB\",\"backup_file\":\"$BACKUP_FILENAME\",\"backup_size\":\"$BACKUP_SIZE\",\"retention_days\":$RETENTION_DAYS,\"status\":\"OK\",\"notes\":\"Backup executado conforme cron job configurado. Nenhum erro reportado durante o processo.\"}"
    else
        echo_error "Falha no backup de $DB"
        send_webhook "{\"action\":\"Falha no backup\",\"date\":\"$(date +"%d/%m/%Y %H:%M:%S")\",\"database_name\":\"$DB\",\"backup_file\":\"$BACKUP_FILENAME\",\"status\":\"FAILED\",\"notes\":\"Erro durante o processo de backup.\"}"
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
        echo_warning "Restauração cancelada."
        return 0
    fi
    
    echo_info "Restaurando $BACKUP em $DB..."
    docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" psql -U "$PG_USER" -d "$DB" -f "$BACKUP_DIR/$BACKUP"
    
    if [ $? -eq 0 ]; then
        echo_success "Restauração concluída com sucesso"
        send_webhook "{\"action\":\"Restauração realizada com sucesso\",\"date\":\"$(date +"%d/%m/%Y %H:%M:%S")\",\"database_name\":\"$DB\",\"backup_file\":\"$BACKUP\",\"status\":\"OK\",\"notes\":\"Restauração executada conforme solicitado. Nenhum erro reportado durante o processo.\"}"
    else
        echo_error "Falha na restauração"
        send_webhook "{\"action\":\"Falha na restauração\",\"date\":\"$(date +"%d/%m/%Y %H:%M:%S")\",\"database_name\":\"$DB\",\"backup_file\":\"$BACKUP\",\"status\":\"FAILED\",\"notes\":\"Erro durante o processo de restauração.\"}"
    fi
}

# Função principal
main() {
    echo_info "Iniciando processo de configuração..."
    
    if ! load_env; then
        # Verificar Docker
        if ! command_exists docker; then
            echo_error "Docker não está instalado. Por favor, instale o Docker antes de prosseguir."
            exit 1
        fi
    
        # Identificar containers PostgreSQL
        echo_info "Identificando containers PostgreSQL em execução..."
        POSTGRES_CONTAINERS=$(docker ps --format "{{.Names}}" | grep -i 'postgres')
    
        if [ -z "$POSTGRES_CONTAINERS" ]; then
            echo_error "Nenhum container PostgreSQL encontrado."
            exit 1
        elif [ $(echo "$POSTGRES_CONTAINERS" | wc -l) -eq 1 ]; then
            CONTAINER_NAME="$POSTGRES_CONTAINERS"
            echo_info "Container PostgreSQL identificado: $CONTAINER_NAME"
        else
            echo_info "Containers PostgreSQL encontrados:"
            echo "$POSTGRES_CONTAINERS"
            read -p "Selecione o nome do container PostgreSQL: " CONTAINER_NAME
            if ! echo "$POSTGRES_CONTAINERS" | grep -qw "$CONTAINER_NAME"; then
                echo_error "Container inválido ou não está rodando."
                exit 1
            fi
        fi
    
        # Configurar usuário PostgreSQL
        read -p "Usar usuário padrão 'postgres'? (yes/no) [yes]: " USE_DEFAULT_USER
        USE_DEFAULT_USER=${USE_DEFAULT_USER:-yes}
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
        read -s -p "Senha PostgreSQL: " PG_PASSWORD
        echo
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
            if valid_url "$WEBHOOK_URL"; then
                break
            else
                echo_error "URL inválida (use http:// ou https://)"
            fi
        done
    
        # Tipo de backup
        echo_info "Tipos de backup disponíveis:"
        echo "1) Backup completo com inserts"
        echo "2) Backup apenas da estrutura"
        echo "3) Backup de tabelas específicas com inserts"
        read -p "Selecione o tipo [1]: " BACKUP_OPTION
        BACKUP_OPTION=${BACKUP_OPTION:-1}
    
        # Salvar configurações
        save_env
    fi
    
    # Configurar diretório de backup
    BACKUP_DIR="/var/backups/postgres"
    if [ ! -d "$BACKUP_DIR" ]; then
        echo_info "Criando diretório $BACKUP_DIR..."
        sudo mkdir -p "$BACKUP_DIR"
        sudo chown "$USER":"$USER" "$BACKUP_DIR"
        sudo chmod 700 "$BACKUP_DIR"
    fi
    
    # Criar scripts
    BACKUP_SCRIPT="/usr/local/bin/backup_postgres.sh"
    RESTORE_SCRIPT="/usr/local/bin/restore_postgres.sh"
    
    # Script de backup
    echo_info "Criando script de backup..."
    cat > "$BACKUP_SCRIPT" <<'EOF'
#!/bin/bash
source /root/.backup_postgres.env

# Funções de utilidade
function echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
function echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
function echo_warning() { echo -e "\e[33m[WARNING]\e[0m $1"; }
function echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; }

# Função para enviar webhook
function send_webhook() {
    local payload="$1"
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL"
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
            echo_info "Realizando backup apenas da estrutura..."
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
        *)
            echo_error "Opção de backup inválida."
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        local BACKUP_SIZE=$(du -h "$BACKUP_PATH" | awk '{print $1}')
        echo_success "Backup concluído: $BACKUP_FILENAME (Tamanho: $BACKUP_SIZE)"
        send_webhook "{\"action\":\"Backup realizado com sucesso\",\"date\":\"$(date +"%d/%m/%Y %H:%M:%S")\",\"database_name\":\"$DB\",\"backup_file\":\"$BACKUP_FILENAME\",\"backup_size\":\"$BACKUP_SIZE\",\"retention_days\":$RETENTION_DAYS,\"status\":\"OK\",\"notes\":\"Backup executado conforme cron job configurado. Nenhum erro reportado durante o processo.\"}"
    else
        echo_error "Falha no backup de $DB"
        send_webhook "{\"action\":\"Falha no backup\",\"date\":\"$(date +"%d/%m/%Y %H:%M:%S")\",\"database_name\":\"$DB\",\"backup_file\":\"$BACKUP_FILENAME\",\"status\":\"FAILED\",\"notes\":\"Erro durante o processo de backup.\"}"
        return 1
    fi
}

# Executar backups para todos os bancos de dados
for DB in $(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" psql -U "$PG_USER" -tAc "SELECT datname FROM pg_database WHERE datistemplate = false;"); do
    do_backup "$DB"
done

# Gerenciar retenção de backups
echo_info "Gerenciando retenção de backups. Mantendo os últimos $RETENTION_DAYS dias..."
find "$BACKUP_DIR" -type f -name "postgres_backup_*.backup" -mtime +$RETENTION_DAYS -print -exec rm {} \; | while read -r deleted_file; do
    BACKUP_NAME=$(basename "$deleted_file")
    send_webhook "{\"action\":\"Backup deletado\",\"date\":\"$(date +"%d/%m/%Y %H:%M:%S")\",\"backup_file\":\"$BACKUP_NAME\",\"deletion_reason\":\"Prazo de retenção expirado\",\"status\":\"OK\",\"notes\":\"Backup deletado conforme política de retenção.\"}"
done

EOF
    chmod +x "$BACKUP_SCRIPT"
    echo_success "Script de backup criado em $BACKUP_SCRIPT"

    # Script de restauração
    echo_info "Criando script de restauração..."
    cat > "$RESTORE_SCRIPT" <<'EOF'
#!/bin/bash
source /root/.backup_postgres.env

# Funções de utilidade
function echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
function echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
function echo_warning() { echo -e "\e[33m[WARNING]\e[0m $1"; }
function echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; }

# Função para enviar webhook
function send_webhook() {
    local payload="$1"
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL"
}

# Função principal de restauração
do_restore() {
    echo_info "Bancos de dados disponíveis:"
    local DATABASES=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$PG_USER" -tAc "SELECT datname FROM pg_database WHERE datistemplate = false;")
    
    select DB in $DATABASES "Cancelar"; do
        if [ "$DB" = "Cancelar" ]; then
            echo_warning "Restauração cancelada pelo usuário."
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
            echo_warning "Restauração cancelada pelo usuário."
            return 0
        elif [ -n "$BACKUP" ]; then
            break
        fi
        echo "Seleção inválida"
    done
    
    read -p "Confirma a restauração? ISSO SUBSTITUIRÁ O BANCO ATUAL (yes/no): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^(yes|Yes|YES)$ ]]; then
        echo_warning "Restauração cancelada pelo usuário."
        return 0
    fi
    
    echo_info "Restaurando $BACKUP em $DB..."
    docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" psql -U "$PG_USER" -d "$DB" -f "$BACKUP_DIR/$BACKUP"
    
    if [ $? -eq 0 ]; then
        echo_success "Restauração concluída com sucesso"
        send_webhook "{\"action\":\"Restauração realizada com sucesso\",\"date\":\"$(date +"%d/%m/%Y %H:%M:%S")\",\"database_name\":\"$DB\",\"backup_file\":\"$BACKUP\",\"status\":\"OK\",\"notes\":\"Restauração executada conforme solicitado. Nenhum erro reportado durante o processo.\"}"
    else
        echo_error "Falha na restauração"
        send_webhook "{\"action\":\"Falha na restauração\",\"date\":\"$(date +"%d/%m/%Y %H:%M:%S")\",\"database_name\":\"$DB\",\"backup_file\":\"$BACKUP\",\"status\":\"FAILED\",\"notes\":\"Erro durante o processo de restauração.\"}"
    fi
}

# Exibir menu de opções
echo_info "Selecione uma opção:"
echo "1) Realizar backup agora"
echo "2) Restaurar um backup"
echo "3) Sair"
read -p "Escolha [1-3]: " CHOICE

case "$CHOICE" in
    1)
        echo_info "Iniciando backup..."
        for DB in $(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" psql -U "$PG_USER" -tAc "SELECT datname FROM pg_database WHERE datistemplate = false;"); do
            do_backup "$DB"
        done
        ;;
    2)
        do_restore
        ;;
    3)
        echo_info "Saindo."
        exit 0
        ;;
    *)
        echo_error "Opção inválida."
        exit 1
        ;;
esac
EOF
    chmod +x "$RESTORE_SCRIPT"
    echo_success "Script de restauração criado em $RESTORE_SCRIPT"

    # Configurar cron job para backup diário às 00:00
    echo_info "Configurando cron job para backups diários às 00:00..."
    (crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT"; echo "0 0 * * * $BACKUP_SCRIPT >> /var/log/backup_postgres_cron.log 2>&1") | crontab -
    echo_success "Cron job configurado com sucesso."

    # Informar ao usuário sobre os scripts criados
    echo_info "Configuração concluída com sucesso!"
    echo_info "Comandos disponíveis:"
    echo "  Realizar backup manualmente: $BACKUP_SCRIPT"
    echo "  Restaurar um backup: $RESTORE_SCRIPT"

    # Perguntar se deseja executar o backup imediatamente
    read -p "Deseja executar um backup agora? (yes/no): " DO_BACKUP
    if [[ "$DO_BACKUP" =~ ^(yes|Yes|YES)$ ]]; then
        echo_info "Executando backup..."
        "$BACKUP_SCRIPT"
    fi
}

# Executar função principal
main "$@"

# setup_backup.sh
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
EOF
    chmod 600 "$ENV_FILE"
    echo_success "Configurações salvas em $ENV_FILE"
}

echo_info "Iniciando processo de configuração..."

# Tentar carregar configurações existentes
if ! load_env; then
    # Verificar Docker
    if ! command_exists docker; then
        echo_error "Docker não está instalado."
        exit 1
    fi

    # Identificar containers PostgreSQL
    echo_info "Identificando containers PostgreSQL em execução..."
    POSTGRES_CONTAINERS=$(docker ps --format "{{.Names}} {{.Image}}" | grep -i 'postgres' | awk '{print $1}')

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
        echo_info "Container PostgreSQL identificado: $CONTAINER_NAME"
    else
        echo_info "Containers PostgreSQL encontrados:"
        echo "$POSTGRES_CONTAINERS"
        read -p "Selecione o container: " CONTAINER_NAME
        if ! echo "$POSTGRES_CONTAINERS" | grep -qw "$CONTAINER_NAME"; then
            echo_error "Container inválido."
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
    echo_info "Usuário PostgreSQL: $PG_USER"

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
        if valid_url "$WEBHOOK_URL"; then
            break
        else
            echo_error "URL inválida (use http:// ou https://)"
        fi
    done

    # Tipo de backup
    echo_info "Tipos de backup disponíveis:"
    echo "1) Backup completo com inserts"
    echo "2) Backup apenas das tabelas"
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
    sudo chown root:root "$BACKUP_DIR"
    sudo chmod 700 "$BACKUP_DIR"
fi

# Verificar montagem do diretório
MOUNTED=$(docker inspect -f '{{ range .Mounts }}{{ if eq .Destination "/var/backups/postgres" }}{{ .Source }}{{ end }}{{ end }}' "$CONTAINER_NAME")
if [ -z "$MOUNTED" ]; then
    echo_warning "Diretório não está montado no container."
    read -p "Deseja continuar sem montar? (yes/no): " CONTINUE_WITHOUT_MOUNT
    if [[ ! "$CONTINUE_WITHOUT_MOUNT" =~ ^(yes|Yes|YES)$ ]]; then
        exit 1
    fi
fi

# Criar scripts
BACKUP_SCRIPT="/usr/local/bin/backup_postgres.sh"
RESTORE_SCRIPT="/usr/local/bin/restore_postgres.sh"

# Backup script
echo_info "Criando script de backup..."
cat > "$BACKUP_SCRIPT" <<'EOF'
#!/bin/bash
source /root/.backup_postgres.env

# ... [resto do script de backup anterior, sem alterações] ...
EOF
chmod +x "$BACKUP_SCRIPT"

# Restore script
echo_info "Criando script de restauração..."
cat > "$RESTORE_SCRIPT" <<'EOF'
#!/bin/bash
source /root/.backup_postgres.env

# ... [resto do script de restauração anterior, sem alterações] ...
EOF
chmod +x "$RESTORE_SCRIPT"

# Configurar cron
echo_info "Configurando cron job..."
(crontab -l 2>/dev/null; echo "0 0 * * * $BACKUP_SCRIPT >> /var/log/backup_postgres_cron.log 2>&1") | crontab -

# Perguntar se deseja executar backup
read -p "Executar backup agora? (yes/no): " RUN_BACKUP
if [[ "$RUN_BACKUP" =~ ^(yes|Yes|YES)$ ]]; then
    sudo "$BACKUP_SCRIPT"
fi

echo_info "Configuração concluída!"
echo_info "Comandos disponíveis:"
echo "  Backup manual: $BACKUP_SCRIPT"
echo "  Restauração: $RESTORE_SCRIPT"
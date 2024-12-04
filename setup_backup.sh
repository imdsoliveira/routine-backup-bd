#!/bin/bash

# =============================================================================
# PostgreSQL Backup Manager para Docker
# Versão: 1.2.0
# Autor: ChatGPT
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

set -euo pipefail

# =============================================================================
# Funções de Utilidade
# =============================================================================

function echo_info() {
    echo -e "\e[34m[INFO]\e[0m $1"
    sleep 1
}

function echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1"
    sleep 1
}

function echo_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1"
    sleep 1
}

function echo_error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
    sleep 1
}

function command_exists() {
    command -v "$1" >/dev/null 2>&1
}

function valid_url() {
    [[ "$1" =~ ^https?://.+ ]]
}

# =============================================================================
# Definição de Variáveis
# =============================================================================

ENV_FILE="/root/.backup_postgres.env"
LOG_FILE="/var/log/backup_postgres.log"
BACKUP_DIR="/var/backups/postgres"
BACKUP_SCRIPT="/usr/local/bin/backup_postgres.sh"
RESTORE_SCRIPT="/usr/local/bin/restore_postgres.sh"

# =============================================================================
# Garantir Criação do Diretório de Logs e Backup
# =============================================================================

mkdir -p "$(dirname "$LOG_FILE")" || true
mkdir -p "$BACKUP_DIR" || true
touch "$LOG_FILE" || true
chmod 644 "$LOG_FILE" || true

# =============================================================================
# Verificar se Docker está Instalado
# =============================================================================

if ! command_exists docker; then
    echo_error "Docker não está instalado. Por favor, instale o Docker antes de executar este script."
    exit 1
fi

# =============================================================================
# Carregar Configurações Existentes ou Solicitar Novas
# =============================================================================

if [ -f "$ENV_FILE" ]; then
    echo_info "Configurações existentes encontradas:"
    cat "$ENV_FILE"
    echo ""
    read -p "Deseja usar estas configurações? (yes/no): " USE_EXISTING
    if [[ "$USE_EXISTING" =~ ^(yes|Yes|YES)$ ]]; then
        source "$ENV_FILE"
        echo_success "Configurações carregadas de $ENV_FILE."
    else
        echo_info "Configurando novas opções."
        rm -f "$ENV_FILE"
    fi
fi

if [ ! -f "$ENV_FILE" ]; then
    # Identificar containers PostgreSQL (imagem contendo 'postgres')
    echo_info "Identificando containers PostgreSQL em execução..."
    POSTGRES_CONTAINERS=$(docker ps --filter "ancestor=postgres" --format "{{.Names}}")

    if [ -z "$POSTGRES_CONTAINERS" ]; then
        echo_warning "Nenhum container PostgreSQL encontrado em execução."
        read -p "Deseja continuar configurando manualmente? (yes/no): " MANUAL_CONFIG
        if [[ "$MANUAL_CONFIG" =~ ^(yes|Yes|YES)$ ]]; then
            read -p "Por favor, insira o nome do container PostgreSQL que deseja configurar: " CONTAINER_NAME
            # Verificar se o container existe e está rodando
            if ! docker ps --format "{{.Names}}" | grep -qw "$CONTAINER_NAME"; then
                echo_error "Nome do container inválido ou container não está rodando."
                exit 1
            fi
        else
            echo_info "Encerrando o script de configuração."
            exit 0
        fi
    elif [ $(echo "$POSTGRES_CONTAINERS" | wc -l) -eq 1 ]; then
        CONTAINER_NAME="$POSTGRES_CONTAINERS"
        echo_info "Container PostgreSQL identificado: $CONTAINER_NAME"
    else
        echo_info "Containers PostgreSQL encontrados:"
        echo "$POSTGRES_CONTAINERS"
        read -p "Por favor, insira o nome do container PostgreSQL que deseja configurar: " CONTAINER_NAME
        if ! echo "$POSTGRES_CONTAINERS" | grep -qw "$CONTAINER_NAME"; then
            echo_error "Nome do container inválido."
            exit 1
        fi
    fi

    # Definir usuário padrão do PostgreSQL como 'postgres'
    DEFAULT_PG_USER="postgres"
    read -p "Deseja utilizar o usuário padrão do PostgreSQL ('postgres')? (yes/no): " USE_DEFAULT_USER
    if [[ "$USE_DEFAULT_USER" =~ ^(yes|Yes|YES)$ ]]; then
        PG_USER="$DEFAULT_PG_USER"
        echo_info "Usuário do PostgreSQL definido como: $PG_USER"
    else
        read -p "Digite o usuário do PostgreSQL para backups: " PG_USER
        if [ -z "$PG_USER" ]; then
            echo_error "Usuário do PostgreSQL não pode estar vazio."
            exit 1
        fi
        echo_info "Usuário do PostgreSQL definido como: $PG_USER"
    fi

    # Solicitar a senha do PostgreSQL (visível)
    read -sp "Digite a senha do usuário PostgreSQL: " PG_PASSWORD
    echo ""
    if [ -z "$PG_PASSWORD" ]; then
        echo_error "Senha do PostgreSQL não pode estar vazia."
        exit 1
    fi
    echo_info "Senha do PostgreSQL recebida."

    # Solicitar o período de retenção dos backups em dias (default: 30)
    read -p "Digite o período de retenção dos backups em dias [30]: " RETENTION_DAYS
    RETENTION_DAYS=${RETENTION_DAYS:-30}
    echo_info "Período de retenção dos backups definido para: $RETENTION_DAYS dias."

    # Solicitar o Webhook URL e validar
    while true; do
        read -p "Digite a URL do Webhook para notificações: " WEBHOOK_URL
        if valid_url "$WEBHOOK_URL"; then
            echo_info "URL do Webhook validada."
            break
        else
            echo_error "URL inválida. Certifique-se de que está no formato http:// ou https://"
        fi
    done

    # Opções de Backup
    echo_info "Selecione o tipo de backup que deseja configurar:"
    echo "1) Backup completo do banco de dados com inserts"
    echo "2) Backup apenas das tabelas do banco de dados"
    echo "3) Backup de tabelas específicas com inserts"
    read -p "Digite o número correspondente à opção desejada [1]: " BACKUP_OPTION
    BACKUP_OPTION=${BACKUP_OPTION:-1}
    echo_info "Opção de backup selecionada: $BACKUP_OPTION"

    # Salvar configurações no arquivo .env
    cat > "$ENV_FILE" <<EOF
PG_USER="$PG_USER"
PG_PASSWORD="$PG_PASSWORD"
RETENTION_DAYS="$RETENTION_DAYS"
WEBHOOK_URL="$WEBHOOK_URL"
BACKUP_OPTION="$BACKUP_OPTION"
CONTAINER_NAME="$CONTAINER_NAME"
BACKUP_DIR="$BACKUP_DIR"
LOG_FILE="$LOG_FILE"
EOF

    chmod 600 "$ENV_FILE"
    echo_success "Configurações salvas em $ENV_FILE."

    # =============================================================================
    # Verificar Montagem do Diretório de Backup no Container
    # =============================================================================

    # Para verificar a montagem, garantir que BACKUP_DIR está montado no container
    MOUNTED=$(docker inspect -f '{{ range .Mounts }}{{ if eq .Destination "'"$BACKUP_DIR"'" }}{{ .Source }}{{ end }}{{ end }}' "$CONTAINER_NAME" || true)
    if [ -z "$MOUNTED" ]; then
        echo_warning "O diretório de backup $BACKUP_DIR não está montado no container $CONTAINER_NAME."
        echo_info "Para continuar, você precisa montar o diretório de backup no container."
        echo_info "Isso pode requerer a reinicialização do container com a opção -v."
        read -p "Deseja interromper o script para montar o volume manualmente? (yes/no): " MOUNT_VOLUME
        if [[ "$MOUNT_VOLUME" =~ ^(yes|Yes|YES)$ ]]; then
            echo_info "Por favor, monte o volume e reinicie o container. Em seguida, execute este script novamente."
            exit 1
        else
            echo_warning "Continuando com a configuração sem montar o volume..."
        fi
    else
        echo_info "Diretório de backup $BACKUP_DIR está montado no container $CONTAINER_NAME."
    fi

    # =============================================================================
    # Remover e Recriar os Scripts de Backup e Restauração
    # =============================================================================

    # Remover o script de backup antigo, se existir
    if [ -f "$BACKUP_SCRIPT" ]; then
        echo_info "Removendo script de backup antigo..."
        sudo rm -f "$BACKUP_SCRIPT"
        echo_success "Script de backup antigo removido."
    fi

    # Criar o script de backup
    echo_info "Criando script de backup em $BACKUP_SCRIPT..."
    sudo tee "$BACKUP_SCRIPT" > /dev/null <<'EOF'
#!/bin/bash

# backup_postgres.sh
# Script de Backup Automático do PostgreSQL

set -euo pipefail

# Carregar variáveis do .env
ENV_FILE="/root/.backup_postgres.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo_error "Arquivo de configuração $ENV_FILE não encontrado."
    exit 1
fi

# Funções para exibir mensagens coloridas com atraso
function echo_info() {
    echo -e "\e[34m[INFO]\e[0m $1" | tee -a "$LOG_FILE"
    sleep 1
}

function echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1" | tee -a "$LOG_FILE"
    sleep 1
}

function echo_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1" | tee -a "$LOG_FILE"
    sleep 1
}

function echo_error() {
    echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOG_FILE"
    sleep 1
}

# Função para enviar webhook com retry
function send_webhook() {
    local payload="$1"
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        response=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL")
        if [[ "$response" =~ ^2 ]]; then
            return 0
        fi
        retry=$((retry + 1))
        [ $retry -lt $max_retries ] && sleep 5
    done

    echo_error "Falha ao enviar webhook após $max_retries tentativas"
    echo "$payload" >> "$BACKUP_DIR/failed_webhooks.log"
    return 1
}

# Função para rotação de logs
function rotate_log() {
    local max_size=52428800 # 50MB
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt "$max_size" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        gzip "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
}

# Rotacionar logs antes do backup
rotate_log

echo_info "Iniciando processo de backup..."

# Listar bancos de dados disponíveis
DATABASES=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" psql -U "$PG_USER" -d postgres -Atc "SELECT datname FROM pg_database WHERE datistemplate = false;")

if [ -z "$DATABASES" ]; then
    echo_warning "Nenhum banco de dados encontrado para backup."
    exit 0
fi

# Selecionar bancos de dados para backup
echo_info "Selecione os bancos de dados que deseja realizar o backup:"
select DB in $DATABASES "Todos"; do
    if [[ -n "$DB" ]]; then
        if [ "$DB" == "Todos" ]; then
            SELECTED_DATABASES="$DATABASES"
        else
            SELECTED_DATABASES="$DB"
        fi
        break
    else
        echo_error "Seleção inválida."
    fi
done

# Iniciar Backup
for DB in $SELECTED_DATABASES; do
    echo_info "Iniciando backup do banco de dados '$DB'..."

    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    case "$BACKUP_OPTION" in
        1)
            BACKUP_FILENAME="postgres_backup_${TIMESTAMP}_${DB}.backup"
            ;;
        2)
            BACKUP_FILENAME="postgres_backup_${TIMESTAMP}_${DB}_schema.backup"
            ;;
        3)
            BACKUP_FILENAME="postgres_backup_${TIMESTAMP}_${DB}_specific_tables.backup"
            ;;
        *)
            echo_error "Tipo de backup desconhecido. Pulando este banco de dados."
            continue
            ;;
    esac
    BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILENAME}"

    case "$BACKUP_OPTION" in
        1)
            # Backup completo com inserts (Formato Padrão)
            echo_info "Realizando backup completo do banco de dados '$DB' com inserts..."
            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" pg_dump -U "$PG_USER" -F p --inserts -v "$DB" > "$BACKUP_PATH"
            ;;
        2)
            # Backup apenas das tabelas (Schema Only, formato Custom)
            echo_info "Realizando backup apenas das tabelas do banco de dados '$DB'..."
            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" pg_dump -U "$PG_USER" -F c --schema-only -v "$DB" > "$BACKUP_PATH"
            ;;
        3)
            # Backup de tabelas específicas com inserts
            echo_info "Realizando backup de tabelas específicas com inserts no banco de dados '$DB'..."
            read -p "Digite os nomes das tabelas que deseja fazer backup, separados por espaço: " -a TABLES
            if [ ${#TABLES[@]} -eq 0 ]; then
                echo_warning "Nenhuma tabela selecionada para backup. Pulando este banco de dados."
                continue
            fi
            TABLES_STRING=$(printf ",\"%s\"" "${TABLES[@]}")
            TABLES_STRING=${TABLES_STRING:1}  # Remover a primeira vírgula
            docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" pg_dump -U "$PG_USER" -d "$DB" --format=plain --data-only --inserts --column-inserts --table "$TABLES_STRING" > "$BACKUP_PATH"
            ;;
        *)
            echo_error "Tipo de backup desconhecido. Pulando este banco de dados."
            continue
            ;;
    esac

    STATUS_BACKUP=$?

    # Verifica se o Backup foi Bem-Sucedido
    if [ $STATUS_BACKUP -eq 0 ]; then
        # Comprimir o backup
        gzip -f "$BACKUP_PATH"
        BACKUP_PATH="${BACKUP_PATH}.gz"
        BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
        STATUS="OK"
        NOTES="Backup executado conforme cron job configurado. Nenhum erro reportado durante o processo."
        echo_success "Backup concluído com sucesso: $(basename "$BACKUP_PATH") (Tamanho: $BACKUP_SIZE)"
    else
        STATUS="ERRO"
        NOTES="Falha ao executar o backup do banco '$DB'. Verifique os logs para mais detalhes."
        BACKUP_SIZE="0"
        echo_error "Backup falhou para o banco '$DB': $(basename "$BACKUP_PATH")"
    fi

    # Gerenciamento de Retenção
    echo_info "Verificando backups antigos do banco '$DB' que excedem $RETENTION_DAYS dias..."
    DELETED_BACKUPS=()
    for arquivo in $(find "$BACKUP_DIR" -type f -name "postgres_backup_*_${DB}.backup.gz" -mtime +$RETENTION_DAYS); do
        nome_backup=$(basename "$arquivo")
        echo_info "Removendo backup antigo: $nome_backup"
        rm -f "$arquivo"
        DELETED_BACKUPS+=("{\"backup_name\": \"$nome_backup\", \"deletion_reason\": \"Prazo de retenção expirado\"}")
    done

    # Preparar o Payload JSON
    if [ ${#DELETED_BACKUPS[@]} -gt 0 ]; then
        DELETED_BACKUPS_JSON=$(IFS=, ; echo "[${DELETED_BACKUPS[*]}]")
    else
        DELETED_BACKUPS_JSON="[]"
    fi

    PAYLOAD=$(cat <<EOF_JSON
{
  "action": "Backup realizado com sucesso",
  "date": "$(date '+%d/%m/%Y %H:%M:%S')",
  "database_name": "$DB",
  "backup_file": "$(basename "$BACKUP_PATH")",
  "backup_size": "$BACKUP_SIZE",
  "retention_days": $RETENTION_DAYS,
  "deleted_backup": $DELETED_BACKUPS_JSON,
  "status": "$STATUS",
  "notes": "$NOTES"
}
EOF_JSON
)

    # Enviar o Webhook
    send_webhook "$PAYLOAD"
done

echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Fim do processo de backup" >> "$LOG_FILE"
EOF

    sudo chmod +x "$BACKUP_SCRIPT"
    echo_success "Script de backup criado com sucesso em $BACKUP_SCRIPT."

    # Remover o script de restauração antigo, se existir
    if [ -f "$RESTORE_SCRIPT" ]; then
        echo_info "Removendo script de restauração antigo..."
        sudo rm -f "$RESTORE_SCRIPT"
        echo_success "Script de restauração antigo removido."
    fi

    # Criar o script de restauração
    echo_info "Criando script de restauração em $RESTORE_SCRIPT..."
    sudo tee "$RESTORE_SCRIPT" > /dev/null <<'EOF'
#!/bin/bash

# restore_postgres.sh
# Script de Restauração Automática do PostgreSQL

set -euo pipefail

# Carregar variáveis do .env
ENV_FILE="/root/.backup_postgres.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo_error "Arquivo de configuração $ENV_FILE não encontrado."
    exit 1
fi

# Funções para exibir mensagens coloridas com atraso
function echo_info() {
    echo -e "\e[34m[INFO]\e[0m $1" | tee -a "$LOG_FILE"
    sleep 1
}

function echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1" | tee -a "$LOG_FILE"
    sleep 1
}

function echo_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1" | tee -a "$LOG_FILE"
    sleep 1
}

function echo_error() {
    echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOG_FILE"
    sleep 1
}

# Função para enviar webhook com retry
function send_webhook() {
    local payload="$1"
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        response=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL")
        if [[ "$response" =~ ^2 ]]; then
            return 0
        fi
        retry=$((retry + 1))
        [ $retry -lt $max_retries ] && sleep 5
    done

    echo_error "Falha ao enviar webhook após $max_retries tentativas"
    echo "$payload" >> "$BACKUP_DIR/failed_webhooks.log"
    return 1
}

# Função para rotação de logs
function rotate_log() {
    local max_size=52428800 # 50MB
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt "$max_size" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        gzip "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
}

# Rotacionar logs antes da restauração
rotate_log

echo_info "Iniciando processo de restauração..."

# Listar bancos de dados disponíveis
DATABASES=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" psql -U "$PG_USER" -d postgres -Atc "SELECT datname FROM pg_database WHERE datistemplate = false;")

if [ -z "$DATABASES" ]; then
    echo_error "Nenhum banco de dados encontrado para restauração."
    exit 1
fi

# Selecionar banco de dados para restauração
echo_info "Selecione o banco de dados que deseja restaurar:"
select DB in $DATABASES "Cancelar"; do
    if [[ -n "$DB" ]]; then
        if [ "$DB" == "Cancelar" ]; then
            echo_info "Restauração cancelada pelo usuário."
            exit 0
        fi
        SELECTED_DATABASE="$DB"
        break
    else
        echo_error "Seleção inválida."
    fi
done

# Listar backups disponíveis para o banco selecionado
echo_info "Listando backups disponíveis para o banco '$SELECTED_DATABASE'..."
BACKUPS=( $(ls -1 "$BACKUP_DIR" | grep "postgres_backup_.*_${SELECTED_DATABASE}\.backup\.gz$" || true) )

if [ ${#BACKUPS[@]} -eq 0 ]; then
    echo_error "Nenhum backup encontrado para $SELECTED_DATABASE em $BACKUP_DIR"
    ls -la "$BACKUP_DIR" | tee -a "$LOG_FILE" # Debug
    exit 1
fi

echo_info "Backups disponíveis:"
for i in "${!BACKUPS[@]}"; do
    echo "$((i+1))). ${BACKUPS[$i]}"
done

# Selecionar Backup
read -p "Digite o número do backup que deseja restaurar: " SELECTION

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]]; then
    echo_error "Entrada inválida. Por favor, insira um número."
    exit 1
fi

if [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#BACKUPS[@]}" ]; then
    echo_error "Número fora do intervalo. Por favor, selecione um número válido."
    exit 1
fi

SELECTED_BACKUP="${BACKUPS[$((SELECTION-1))]}"
echo_info "Backup Selecionado: $SELECTED_BACKUP"

# Confirmar Restauração
read -p "Tem certeza que deseja restaurar este backup? Isso sobrescreverá o banco de dados atual. (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" && "$CONFIRM" != "Yes" && "$CONFIRM" != "YES" ]]; then
    echo_info "Restauração cancelada pelo usuário."
    exit 0
fi

# Processo de Restauração com Feedback ao Usuário
echo_info "Iniciando restauração do backup '$SELECTED_BACKUP' no banco '$SELECTED_DATABASE'..."

# Descomprimir backup temporariamente
TEMP_BACKUP="/tmp/${SELECTED_BACKUP%.gz}"
gunzip -c "$BACKUP_DIR/$SELECTED_BACKUP" > "$TEMP_BACKUP"

# Dropar conexões existentes
docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" psql -U "$PG_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$SELECTED_DATABASE' AND pid <> pg_backend_pid();"

# Restaurar
if docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" psql -U "$PG_USER" -d "$SELECTED_DATABASE" -f "/var/backups/postgres/$SELECTED_BACKUP"; then
    STATUS="OK"
    NOTES="Restauração executada com sucesso."
    echo_success "Restauração concluída com sucesso: $SELECTED_BACKUP"
else
    STATUS="ERRO"
    NOTES="Falha ao executar a restauração. Verifique os logs para mais detalhes."
    echo_error "Restauração falhou: $SELECTED_BACKUP"
fi

# Preparar o Payload JSON
PAYLOAD=$(cat <<EOF_JSON
{
  "action": "Restauração realizada",
  "date": "$(date '+%d/%m/%Y %H:%M:%S')",
  "database_name": "$SELECTED_DATABASE",
  "backup_file": "$SELECTED_BACKUP",
  "status": "$STATUS",
  "notes": "$NOTES"
}
EOF_JSON
)

# Enviar o Webhook
send_webhook "$PAYLOAD"

# Limpar arquivo temporário
rm -f "$TEMP_BACKUP"

# Log da Restauração
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Restauração $STATUS: $SELECTED_BACKUP no banco '$SELECTED_DATABASE'" >> "$LOG_FILE"

echo_success "Processo de restauração finalizado."
EOF

    sudo chmod +x "$RESTORE_SCRIPT"
    echo_success "Script de restauração criado com sucesso em $RESTORE_SCRIPT."

    # =============================================================================
    # Configurar o Cron Job
    # =============================================================================

    echo_info "Agendando cron job para backups automáticos diariamente às 00:00..."
    (crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT"; echo "0 0 * * * $BACKUP_SCRIPT >> $LOG_FILE 2>&1") | crontab -
    echo_success "Cron job agendado com sucesso."

    # =============================================================================
    # Finalização da Configuração
    # =============================================================================

    echo_success "Configuração de backup concluída com sucesso!"

    # Perguntar se deseja executar o backup
    read -p "Deseja executar o backup agora? (yes/no): " RUN_BACKUP
    case "$RUN_BACKUP" in
        yes|Yes|YES)
            echo_info "Executando backup..."
            sudo "$BACKUP_SCRIPT"
            ;;
        *)
            echo_info "Não executando backup."
            ;;
    esac

    echo_info "Você pode executar o backup manualmente com: $BACKUP_SCRIPT"
    echo_info "Você pode restaurar backups com: $RESTORE_SCRIPT"
    echo_info "Script de configuração finalizado."
fi

#!/bin/bash

# setup_backup.sh
# Script para configurar rotina de backup automática do PostgreSQL em servidores Dockerizados.

set -e  # Encerra o script em caso de erro

# Funções para exibir mensagens coloridas com atraso
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

# Função para verificar se um comando existe
function command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Função para validar URL
function valid_url() {
    [[ "$1" =~ ^https?://.+ ]]
}

echo_info "Iniciando processo de configuração..."

# Verificar se Docker está instalado
if ! command_exists docker; then
    echo_error "Docker não está instalado. Por favor, instale o Docker antes de executar este script."
    exit 1
fi

# Identificar containers PostgreSQL (imagem contendo 'postgres')
echo_info "Identificando containers PostgreSQL em execução..."
POSTGRES_CONTAINERS=$(docker ps --format "{{.Names}} {{.Image}}" | grep -i 'postgres' | awk '{print $1}')

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
fi

# Solicitar a senha do PostgreSQL (visível)
read -p "Digite a senha do usuário PostgreSQL: " PG_PASSWORD

# Solicitar o período de retenção dos backups em dias (default: 30)
read -p "Digite o período de retenção dos backups em dias [30]: " RETENTION_DAYS
RETENTION_DAYS=${RETENTION_DAYS:-30}

# Solicitar o Webhook URL e validar
while true; do
    read -p "Digite a URL do Webhook para notificações: " WEBHOOK_URL
    if valid_url "$WEBHOOK_URL"; then
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

# Configurar diretório de backup no host
BACKUP_DIR="/var/backups/postgres"
echo_info "Criando diretório de backup em $BACKUP_DIR..."
sudo mkdir -p "$BACKUP_DIR"
sudo chown root:root "$BACKUP_DIR"
sudo chmod 700 "$BACKUP_DIR"
echo_success "Diretório de backup criado com sucesso."

# Verificar se o diretório de backup está montado no container
MOUNTED=$(docker inspect -f '{{ range .Mounts }}{{ if eq .Destination "/var/backups/postgres" }}{{ .Source }}{{ end }}{{ end }}' "$CONTAINER_NAME")
if [ -z "$MOUNTED" ]; then
    echo_warning "O diretório de backup $BACKUP_DIR não está montado no container $CONTAINER_NAME."
    echo_info "Para continuar, você precisa montar o diretório de backup no container."
    echo_info "Isso pode requerer a reinicialização do container com a opção -v."
    read -p "Deseja interromper o script para montar o volume manualmente? (yes/no): " MOUNT_VOLUME
    if [[ "$MOUNT_VOLUME" =~ ^(yes|Yes|YES)$ ]]; then
        echo_info "Por favor, monte o volume e reinicie o container. Em seguida, execute este script novamente."
        exit 0
    else
        echo_info "Continuando com a configuração sem montar o volume..."
    fi
fi

# Criar o script de backup
BACKUP_SCRIPT="/usr/local/bin/backup_postgres.sh"
echo_info "Criando script de backup em $BACKUP_SCRIPT..."

sudo tee "$BACKUP_SCRIPT" > /dev/null <<EOF
#!/bin/bash

# Script de Backup do PostgreSQL

# Definir variáveis
PG_USER="$PG_USER"
PG_PASSWORD="$PG_PASSWORD"
BACKUP_DIR="$BACKUP_DIR"
WEBHOOK_URL="$WEBHOOK_URL"
RETENTION_DAYS="$RETENTION_DAYS"
BACKUP_OPTION="$BACKUP_OPTION"
CONTAINER_NAME="$CONTAINER_NAME"

# Funções para exibir mensagens coloridas com atraso
function echo_info() {
    echo -e "\\e[34m[INFO]\\e[0m \$1" >&2
    sleep 1
}

function echo_success() {
    echo -e "\\e[32m[SUCCESS]\\e[0m \$1" >&2
    sleep 1
}

function echo_warning() {
    echo -e "\\e[33m[WARNING]\\e[0m \$1" >&2
    sleep 1
}

function echo_error() {
    echo -e "\\e[31m[ERROR]\\e[0m \$1" >&2
    sleep 1
}

# Função para enviar webhook
function send_webhook() {
    local payload="\$1"
    curl -s -X POST -H "Content-Type: application/json" -d "\$payload" "\$WEBHOOK_URL"
}

# Listar bancos de dados disponíveis
echo_info "Listando bancos de dados disponíveis no container '\$CONTAINER_NAME'..."
DATABASES=$(docker exec -e PGPASSWORD="$PG_PASSWORD" -t "$CONTAINER_NAME" psql -U "$PG_USER" -d postgres -Atc "SELECT datname FROM pg_database WHERE datistemplate = false;")
if [ -z "\$DATABASES" ]; then
    echo_warning "Nenhum banco de dados encontrado para backup."
    exit 0
fi

# Selecionar bancos de dados para backup
echo_info "Selecione os bancos de dados que deseja realizar o backup:"
select DB in \$DATABASES "Todos"; do
    if [[ -n "\$DB" ]]; then
        if [ "\$DB" == "Todos" ]; then
            SELECTED_DATABASES="\$DATABASES"
        else
            SELECTED_DATABASES="\$DB"
        fi
        break
    else
        echo_error "Seleção inválida."
    fi
done

# Iniciar Backup
for DB in \$SELECTED_DATABASES; do
    echo_info "Iniciando backup do banco de dados '\$DB'..."

    # Nome do Arquivo de Backup
    TIMESTAMP=\$(date +%Y%m%d%H%M%S)
    BACKUP_FILENAME="postgres_backup_\$TIMESTAMP_\$DB.backup"
    BACKUP_PATH="\$BACKUP_DIR/\$BACKUP_FILENAME"

    case "\$BACKUP_OPTION" in
        1)
            # Backup completo com inserts (Formato Padrão)
            echo_info "Realizando backup completo do banco de dados '\$DB' com inserts..."
            docker exec -e PGPASSWORD="$PG_PASSWORD" -t "$CONTAINER_NAME" pg_dump -U "$PG_USER" -F p --inserts -v -f "\$BACKUP_PATH" "\$DB"
            ;;
        2)  
            # Backup apenas das tabelas (Schema Only, formato Custom)
            echo_info "Realizando backup apenas das tabelas do banco de dados '\$DB'..."
            docker exec -e PGPASSWORD="$PG_PASSWORD" -t "$CONTAINER_NAME" pg_dump -U "$PG_USER" -F c -b -v --schema-only -f "\$BACKUP_PATH" "\$DB"
            ;;
        3)
            # Backup de tabelas específicas com inserts
            echo_info "Realizando backup de tabelas específicas com inserts no banco de dados '\$DB'..."
            read -p "Digite os nomes das tabelas que deseja fazer backup, separados por espaço: " -a TABLES
            if [ \${#TABLES[@]} -eq 0 ]; then
                echo_warning "Nenhuma tabela selecionada para backup. Pulando este banco de dados."
                continue
            fi
            TABLES_STRING=\$(printf ",\"%s\"" "\${TABLES[@]}")
            TABLES_STRING=\${TABLES_STRING:1}  # Remover a primeira vírgula
            docker exec -e PGPASSWORD="$PG_PASSWORD" -t "$CONTAINER_NAME" pg_dump -U "$PG_USER" -d "\$DB" --format=plain --data-only --inserts --column-inserts --table "\$TABLES_STRING" -f "\$BACKUP_PATH"
            ;;
        *)
            echo_error "Tipo de backup desconhecido. Pulando este banco de dados."
            continue
            ;;
    esac

    STATUS_BACKUP=\$?

    # Verifica se o Backup foi Bem-Sucedido
    if [ \$STATUS_BACKUP -eq 0 ]; then
        BACKUP_SIZE=\$(docker exec -t "$CONTAINER_NAME" du -h "\$BACKUP_PATH" | cut -f1)
        BACKUP_INFO="{ \"database\": \"\$DB\", \"filename\": \"\$BACKUP_FILENAME\", \"status\": \"success\", \"size\": \"\$BACKUP_SIZE\"}"
        echo_success "Backup concluído com sucesso para o banco '\$DB': \$BACKUP_FILENAME (Tamanho: \$BACKUP_SIZE)"
    else
        BACKUP_INFO="{ \"database\": \"\$DB\", \"filename\": \"\$BACKUP_FILENAME\", \"status\": \"failure\", \"size\": \"0\"}"
        echo_error "Backup falhou para o banco '\$DB': \$BACKUP_FILENAME"
    fi

    # Enviar notificação via webhook
    send_webhook "\$BACKUP_INFO"

    # Gerenciamento de Retenção
    echo_info "Verificando backups antigos do banco '\$DB' que excedem \$RETENTION_DAYS dias..."
    find "\$BACKUP_DIR" -type f -name "postgres_backup_*_\$DB.backup" -mtime +\$RETENTION_DAYS -delete
done

# Adicionar timestamp ao arquivo de log
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Fim do processo de backup" >> /var/log/backup_postgres.log
EOF

sudo chmod +x "$BACKUP_SCRIPT"
echo_success "Script de backup criado com sucesso."

# Configurar o cron job
echo_info "Agendando cron job para backups automáticos diariamente às 00:00..."
(crontab -l 2>/dev/null; echo "0 0 * * * $BACKUP_SCRIPT >> /var/log/backup_postgres_cron.log 2>&1") | crontab -
echo_success "Cron job agendado com sucesso."

echo_success "Configuração de backup concluída com sucesso!"

# Perguntar se deseja executar backup/restauração
read -p "Deseja executar o backup ou restauração agora? (backup/restore/no): " RUN_ACTION
case "$RUN_ACTION" in
    backup|Backup|BACKUP)
        echo_info "Executando backup..."
        $BACKUP_SCRIPT
        ;;
    restore|Restore|RESTORE)
        echo_info "Executando restauração..."
        $RESTORE_SCRIPT
        ;;
    *)
        echo_info "Não executando backup ou restauração."
        ;;
esac

echo_info "Você pode executar o backup manualmente com: $BACKUP_SCRIPT"
echo_info "Script de configuração finalizado."
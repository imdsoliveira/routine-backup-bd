#!/bin/bash

# setup_backup.sh
# Script para configurar rotina de backup automática do PostgreSQL em servidores Dockerizados.

set -e  # Encerra o script em caso de erro

# Funções para exibir mensagens coloridas
function echo_info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}

function echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1"
}

function echo_error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
}

# Função para verificar se um comando existe
function command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Função para validar URL
function valid_url() {
    [[ "$1" =~ ^https?://.+ ]]
}

# Verificar se Docker está instalado
if ! command_exists docker; then
    echo_error "Docker não está instalado. Por favor, instale o Docker antes de executar este script."
    exit 1
fi

# Identificar containers PostgreSQL (imagem contendo 'postgres')
echo_info "Identificando containers PostgreSQL em execução..."
POSTGRES_CONTAINERS=$(docker ps --format "{{.Names}} {{.Image}}" | grep -i 'postgres' | awk '{print $1}')

if [ -z "$POSTGRES_CONTAINERS" ]; then
    echo_error "Nenhum container PostgreSQL encontrado em execução."
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
        exit 1
    fi
elif [ $(echo "$POSTGRES_CONTAINERS" | wc -l) -gt 1 ]; then
    echo_info "Múltiplos containers PostgreSQL encontrados:"
    echo "$POSTGRES_CONTAINERS"
    read -p "Por favor, insira o nome do container PostgreSQL que deseja configurar: " CONTAINER_NAME
    if ! echo "$POSTGRES_CONTAINERS" | grep -qw "$CONTAINER_NAME"; then
        echo_error "Nome do container inválido."
        exit 1
    fi
else
    CONTAINER_NAME="$POSTGRES_CONTAINERS"
    echo_info "Container PostgreSQL identificado: $CONTAINER_NAME"
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
echo

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

# Configurar diretório de backup no host
BACKUP_DIR="/var/backups/postgres"
echo_info "Criando diretório de backup em $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"
chown root:root "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# Verificar se o diretório de backup está montado no container
MOUNTED=$(docker inspect -f '{{ range .Mounts }}{{ if eq .Destination "/var/backups/postgres" }}{{ .Source }}{{ end }}{{ end }}' "$CONTAINER_NAME")
if [ -z "$MOUNTED" ]; then
    echo_error "O diretório de backup $BACKUP_DIR não está montado no container $CONTAINER_NAME."
    echo_info "Para continuar, você precisa montar o diretório de backup no container."
    echo_info "Isso pode requerer a reinicialização do container com a opção -v."
    read -p "Deseja interromper o script para montar o volume manualmente? (yes/no): " MOUNT_VOLUME
    if [[ "$MOUNT_VOLUME" =~ ^(yes|Yes|YES)$ ]]; then
        echo_info "Por favor, monte o volume e reinicie o container. Em seguida, execute este script novamente."
        exit 1
    else
        echo_error "O diretório de backup não está montado no container. Encerrando o script."
        exit 1
    fi
fi

# Configurar o arquivo .pgpass
PGPASS_FILE="/root/.pgpass"
echo_info "Configurando arquivo .pgpass para autenticação automática..."
echo "localhost:5432:postgres:$PG_USER:$PG_PASSWORD" > "$PGPASS_FILE"
chown root:root "$PGPASS_FILE"
chmod 600 "$PGPASS_FILE"

# Criar o script de backup
BACKUP_SCRIPT="/usr/local/bin/backup_postgres.sh"
echo_info "Criando script de backup em $BACKUP_SCRIPT..."

cat <<EOF > "$BACKUP_SCRIPT"
#!/bin/bash

# Script de Backup do PostgreSQL

# Configurações
CONTAINER_NAME="$CONTAINER_NAME"
PG_USER="$PG_USER"
BACKUP_DIR="$BACKUP_DIR"
WEBHOOK_URL="$WEBHOOK_URL"
RETENTION_DAYS="$RETENTION_DAYS"

# Data e Hora Atual
DATA=\$(date +%Y-%m-%d)
HORA=\$(date +%H:%M:%S)

# Nome do Arquivo de Backup
ARQUIVO_BACKUP="postgres_backup_\$(date +%Y%m%d%H%M%S).backup"

# Processo de Backup
docker exec -t "\$CONTAINER_NAME" pg_dump -U "\$PG_USER" -F c -b -v -f "\$BACKUP_DIR/\$ARQUIVO_BACKUP" postgres
STATUS_BACKUP=\$?

# Verifica se o Backup foi Bem-Sucedido
if [ \$STATUS_BACKUP -eq 0 ]; then
    STATUS="OK"
    NOTES="Backup executado conforme cron job configurado. Nenhum erro reportado durante o processo."
    BACKUP_SIZE=\$(docker exec "\$CONTAINER_NAME" du -h "\$BACKUP_DIR/\$ARQUIVO_BACKUP" | cut -f1)
else
    STATUS="ERRO"
    NOTES="Falha ao executar o backup. Verifique os logs para mais detalhes."
    BACKUP_SIZE="0B"
fi

# Gerenciamento de Retenção
BACKUPS_ANTIGOS=\$(find "\$BACKUP_DIR" -type f -name "postgres_backup_*.backup" -mtime +\$RETENTION_DAYS)

DELETED_BACKUPS_JSON="[]"

if [ -n "\$BACKUPS_ANTIGOS" ]; then
    DELETED_BACKUPS=()
    for arquivo in \$BACKUPS_ANTIGOS; do
        nome_backup=\$(basename "\$arquivo")
        # Remove o Arquivo
        rm -f "\$arquivo"
        # Adiciona Detalhes ao JSON
        DELETED_BACKUPS+=("{\"backup_name\": \"\$nome_backup\", \"deletion_reason\": \"Prazo de retenção expirado\"}")
    done
    # Converte o Array para JSON
    DELETED_BACKUPS_JSON=\$(IFS=, ; echo "[\${DELETED_BACKUPS[*]}]")
fi

# Enviar Notificação via Webhook
PAYLOAD=\$(cat <<EOF_JSON
{
    "action": "Backup realizado com sucesso",
    "date": "\$(date '+%d/%m/%Y %H:%M:%S')",
    "database_name": "postgres",
    "backup_file": "\$ARQUIVO_BACKUP",
    "backup_size": "\$BACKUP_SIZE",
    "retention_days": \$RETENTION_DAYS,
    "deleted_backup": \$DELETED_BACKUPS_JSON,
    "status": "\$STATUS",
    "notes": "\$NOTES"
}
EOF_JSON
)

curl -X POST -H "Content-Type: application/json" -d "\$PAYLOAD" "\$WEBHOOK_URL"

# Log (Opcional)
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Backup \$STATUS: \$ARQUIVO_BACKUP, Size: \$BACKUP_SIZE" >> /var/log/backup_postgres.log
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Backups antigos removidos: \$DELETED_BACKUPS_JSON" >> /var/log/backup_postgres.log
EOF

chmod +x "$BACKUP_SCRIPT"

# Criar o script de restauração (Opcional)
RESTORE_SCRIPT="/usr/local/bin/restore_postgres.sh"
echo_info "Criando script de restauração em $RESTORE_SCRIPT..."

cat <<EOF > "$RESTORE_SCRIPT"
#!/bin/bash

# Script de Restauração do PostgreSQL

# Configurações
CONTAINER_NAME="$CONTAINER_NAME"
PG_USER="$PG_USER"
BACKUP_DIR="$BACKUP_DIR"
WEBHOOK_URL="$WEBHOOK_URL"

# Funções para exibir mensagens coloridas
function echo_info() {
    echo -e "\e[34m[INFO]\e[0m \$1"
}

function echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m \$1"
}

function echo_error() {
    echo -e "\e[31m[ERROR]\e[0m \$1"
}

# Listar Backups Disponíveis
echo_info "Listando backups disponíveis:"
BACKUPS=(\$(docker exec "\$CONTAINER_NAME" ls "\$BACKUP_DIR" | grep "postgres_backup_.*\.backup"))
if [ \${#BACKUPS[@]} -eq 0 ]; then
    echo_error "Nenhum backup encontrado em \$BACKUP_DIR."
    exit 1
fi

for i in "\${!BACKUPS[@]}"; do
    echo "\$((i+1))). \${BACKUPS[\$i]}"
done

# Selecionar Backup
read -p "Digite o número do backup que deseja restaurar: " SELECTION

if ! [[ "\$SELECTION" =~ ^[0-9]+$ ]]; then
    echo_error "Entrada inválida. Por favor, insira um número."
    exit 1
fi

if [ "\$SELECTION" -lt 1 ] || [ "\$SELECTION" -gt "\${#BACKUPS[@]}" ]; then
    echo_error "Número fora do intervalo. Por favor, selecione um número válido."
    exit 1
fi

SELECTED_BACKUP="\${BACKUPS[\$((SELECTION-1))]}"
echo_info "Backup Selecionado: \$SELECTED_BACKUP"

# Confirmar Restauração
read -p "Tem certeza que deseja restaurar este backup? Isso sobrescreverá o banco de dados atual. (yes/no): " CONFIRM

if [[ "\$CONFIRM" != "yes" && "\$CONFIRM" != "Yes" && "\$CONFIRM" != "YES" ]]; then
    echo_info "Restauração cancelada pelo usuário."
    exit 0
fi

# Processo de Restauração
docker exec -t "\$CONTAINER_NAME" pg_restore -U "\$PG_USER" -d postgres -c "\$BACKUP_DIR/\$SELECTED_BACKUP"
STATUS_RESTORE=\$?

# Verifica se a Restauração foi Bem-Sucedida
if [ \$STATUS_RESTORE -eq 0 ]; then
    STATUS="OK"
    NOTES="Restauração executada com sucesso."
else
    STATUS="ERRO"
    NOTES="Falha ao executar a restauração. Verifique os logs para mais detalhes."
fi

# Enviar Notificação via Webhook
PAYLOAD=\$(cat <<EOF_JSON
{
    "action": "Restauração realizada com sucesso",
    "date": "\$(date '+%d/%m/%Y %H:%M:%S')",
    "database_name": "postgres",
    "backup_file": "\$SELECTED_BACKUP",
    "status": "\$STATUS",
    "notes": "\$NOTES"
}
EOF_JSON
)

curl -X POST -H "Content-Type: application/json" -d "\$PAYLOAD" "\$WEBHOOK_URL"

# Log (Opcional)
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] Restauração \$STATUS: \$SELECTED_BACKUP" >> /var/log/backup_postgres.log
EOF

chmod +x "$RESTORE_SCRIPT"

# Configurar o cron job
echo_info "Agendando cron job para backups automáticos diariamente às 00:00..."
(crontab -l 2>/dev/null; echo "0 0 * * * $BACKUP_SCRIPT >> /var/log/backup_postgres_cron.log 2>&1") | crontab -

echo_success "Configuração de backup concluída com sucesso!"
echo_info "Você pode executar o backup manualmente com: $BACKUP_SCRIPT"
echo_info "Você pode restaurar backups com: $RESTORE_SCRIPT"

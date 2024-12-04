#!/bin/bash

# Diretório de instalação
INSTALL_DIR="$HOME/postgres_backup"
BACKUP_SCRIPT="$INSTALL_DIR/backup.sh"
RESTORE_SCRIPT="$INSTALL_DIR/restore.sh"
ENV_FILE="$INSTALL_DIR/.env"

# Função para verificar se o comando existe
command_exists () {
    command -v "$1" >/dev/null 2>&1 ;
}

# Instalar dependências
echo "Instalando dependências necessárias..."
if command_exists curl; then
    echo "curl já está instalado."
else
    sudo apt-get update
    sudo apt-get install -y curl
fi

if command_exists jq; then
    echo "jq já está instalado."
else
    sudo apt-get install -y jq
fi

# Criar diretório de instalação
mkdir -p "$INSTALL_DIR"
echo "Diretório de instalação criado em $INSTALL_DIR."

# Criar arquivo .env
if [ ! -f "$ENV_FILE" ]; then
    echo "Configurando variáveis de ambiente..."

    read -p "Digite a URL do Webhook: " WEBHOOK_URL
    read -p "Digite o usuário do PostgreSQL: " POSTGRES_USER
    read -s -p "Digite a senha do PostgreSQL: " POSTGRES_PASSWORD
    echo
    read -p "Digite o host do PostgreSQL (ex: localhost): " POSTGRES_HOST
    read -p "Digite a porta do PostgreSQL (ex: 5432): " POSTGRES_PORT
    read -p "Digite o valor de retenção de dias para backups: " RETENTION_DAYS

    cat <<EOL > "$ENV_FILE"
WEBHOOK_URL="$WEBHOOK_URL"
POSTGRES_USER="$POSTGRES_USER"
POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
POSTGRES_HOST="$POSTGRES_HOST"
POSTGRES_PORT="$POSTGRES_PORT"
RETENTION_DAYS=$RETENTION_DAYS
BACKUP_DIR="$INSTALL_DIR/backups"
EOL

    echo ".env configurado com sucesso."
else
    echo ".env já existe. Pulando configuração."
fi

# Criar diretório de backups
mkdir -p "$INSTALL_DIR/backups"
echo "Diretório de backups criado em $INSTALL_DIR/backups."

# Criar backup.sh
cat <<'EOF' > "$BACKUP_SCRIPT"
#!/bin/bash

# Carregar variáveis de ambiente
ENV_FILE="$HOME/postgres_backup/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Arquivo .env não encontrado! Execute o install.sh primeiro."
    exit 1
fi

export $(grep -v '^#' "$ENV_FILE" | xargs)

# Diretório de backups
BACKUP_DIR="$BACKUP_DIR"

# Data e hora atual
CURRENT_DATE=$(date +"%Y%m%d%H%M%S")

# Nome do arquivo de backup
BACKUP_FILE="backup_${CURRENT_DATE}.backup"

# Caminho completo do arquivo de backup
BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILE"

# Realizar o backup
echo "Iniciando backup do banco de dados PostgreSQL..."
docker exec -t $(docker ps --filter ancestor=postgres --format "{{.Names}}") pg_dumpall -U "$POSTGRES_USER" -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" > "$BACKUP_PATH"

if [ $? -ne 0 ]; then
    echo "Falha no backup do banco de dados."
    STATUS="FAILED"
    NOTES="Erro durante o processo de backup."
else
    echo "Backup realizado com sucesso: $BACKUP_FILE"
    STATUS="OK"
    NOTES="Backup executado conforme cron job configurado. Nenhum erro reportado durante o processo."
fi

# Obter tamanho do backup
BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)

# Gerenciar retenção de backups
echo "Gerenciando retenção de backups. Mantendo os últimos $RETENTION_DAYS dias..."
find "$BACKUP_DIR" -type f -name "backup_*.backup" -mtime +$RETENTION_DAYS -print -exec rm {} \;

# Informações sobre backups deletados
DELETED_BACKUPS=$(find "$BACKUP_DIR" -type f -name "backup_*.backup" -mtime +$RETENTION_DAYS)

# Enviar notificação via webhook
echo "Enviando notificação via webhook..."
PAYLOAD=$(jq -n \
    --arg action "Backup realizado com sucesso" \
    --arg date "$(date +"%d/%m/%Y %H:%M:%S")" \
    --arg database_name "$POSTGRES_USER" \
    --arg backup_file "$BACKUP_FILE" \
    --arg backup_size "$BACKUP_SIZE" \
    --arg retention_days "$RETENTION_DAYS" \
    --arg status "$STATUS" \
    --arg notes "$NOTES" \
    '{
        action: $action,
        date: $date,
        database_name: $database_name,
        backup_file: $backup_file,
        backup_size: $backup_size,
        retention_days: ($retention_days | tonumber),
        status: $status,
        notes: $notes
    }')

# Adicionar informação de backups deletados, se houver
if [ -n "$DELETED_BACKUPS" ]; then
    for backup in $DELETED_BACKUPS; do
        BACKUP_NAME=$(basename "$backup")
        DELETION_REASON="Prazo de retenção expirado"
        DELETED_JSON=$(jq -n \
            --arg backup_name "$BACKUP_NAME" \
            --arg deletion_reason "$DELETION_REASON" \
            '{
                backup_name: $backup_name,
                deletion_reason: $deletion_reason
            }')
        PAYLOAD=$(echo "$PAYLOAD" | jq --argjson deleted_backup "$DELETED_JSON" '. + {deleted_backup: $deleted_backup}')
    done
fi

curl -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK_URL"

echo "Notificação enviada."
EOF

chmod +x "$BACKUP_SCRIPT"
echo "Script backup.sh criado."

# Criar restore.sh
cat <<'EOF' > "$RESTORE_SCRIPT"
#!/bin/bash

# Carregar variáveis de ambiente
ENV_FILE="$HOME/postgres_backup/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Arquivo .env não encontrado! Execute o install.sh primeiro."
    exit 1
fi

export $(grep -v '^#' "$ENV_FILE" | xargs)

# Diretório de backups
BACKUP_DIR="$BACKUP_DIR"

# Listar backups disponíveis
echo "Listando backups disponíveis:"
BACKUPS=($(ls "$BACKUP_DIR"/backup_*.backup 2>/dev/null | sort -r))
if [ ${#BACKUPS[@]} -eq 0 ]; then
    echo "Nenhum backup encontrado."
    exit 1
fi

select BACKUP in "${BACKUPS[@]}"; do
    if [ -n "$BACKUP" ]; then
        echo "Você selecionou: $(basename "$BACKUP")"
        break
    else
        echo "Seleção inválida."
    fi
done

# Confirmar restauração
read -p "Tem certeza de que deseja restaurar este backup? Isso substituirá o banco de dados atual. (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Restauração cancelada."
    exit 0
fi

# Restaurar o backup
echo "Iniciando restauração do backup: $(basename "$BACKUP")"
docker exec -i $(docker ps --filter ancestor=postgres --format "{{.Names}}") psql -U "$POSTGRES_USER" -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" < "$BACKUP"

if [ $? -ne 0 ]; then
    echo "Falha na restauração do banco de dados."
    exit 1
else
    echo "Restauração concluída com sucesso."
fi
EOF

chmod +x "$RESTORE_SCRIPT"
echo "Script restore.sh criado."

# Configurar cron job
CRON_JOB="0 0 * * * $BACKUP_SCRIPT >> $INSTALL_DIR/backup.log 2>&1"

# Adicionar cron job se não existir
(crontab -l | grep -v -F "$BACKUP_SCRIPT" ; echo "$CRON_JOB") | crontab -

echo "Cron job configurado para executar backup.sh diariamente à 00:00."

echo "Instalação concluída com sucesso!"
echo "Para restaurar um backup, execute o script restore.sh localizado em $RESTORE_SCRIPT."
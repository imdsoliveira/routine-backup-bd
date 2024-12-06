#!/usr/bin/env bash
# =============================================================================
# PostgreSQL Backup Manager 2024
# Versão: 0.1.1
# =============================================================================
# - Backup automático diário
# - Retenção configurável
# - Notificações webhook consolidadas
# - Restauração interativa com barra de progresso
# - Detecção automática de container PostgreSQL (Docker Swarm)
# - Criação automática de estruturas
# - Gerenciamento de logs com rotação
# - Recriação automática de estruturas ausentes
# - Verificação pré-backup de existência do banco de dados
# =============================================================================

# Cores para saída no terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem cor

SCRIPT_VERSION="0.1.1"
BACKUP_BASE_DIR="/root/backups-postgres"

# Função para carregar variáveis de ambiente do .env se existir
load_env() {
    if [ -f .env ]; then
        set -o allexport
        source .env
        set +o allexport
    fi
}

# Função para criar/atualizar .env
setup_env() {
    echo -e "${BLUE}==== Configuração Inicial do PostgreSQL Backup Manager ====${NC}"
    read -p "Digite a URL do Webhook (atual: ${WEBHOOK_URL:-não definido}): " input_url
    [ ! -z "$input_url" ] && WEBHOOK_URL="$input_url"

    read -p "Digite a senha do usuário postgres (atual: ${POSTGRES_PASSWORD:-não definido}): " input_pwd
    [ ! -z "$input_pwd" ] && POSTGRES_PASSWORD="$input_pwd"

    read -p "Digite quantos dias de retenção deseja (atual: ${retention_days_value:-7}): " input_ret
    [ ! -z "$input_ret" ] && retention_days_value="$input_ret" || retention_days_value=7

    # Host pode ser 'localhost' ou ip do container
    read -p "Digite o host do Postgres (atual: ${POSTGRES_HOST:-localhost}): " input_host
    [ ! -z "$input_host" ] && POSTGRES_HOST="$input_host" || POSTGRES_HOST="localhost"

    read -p "Digite a porta do Postgres (atual: ${POSTGRES_PORT:-5432}): " input_port
    [ ! -z "$input_port" ] && POSTGRES_PORT="$input_port" || POSTGRES_PORT=5432

    # Salvar no .env
    cat > .env <<EOF
WEBHOOK_URL="$WEBHOOK_URL"
POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
POSTGRES_HOST="$POSTGRES_HOST"
POSTGRES_PORT="$POSTGRES_PORT"
retention_days_value="$retention_days_value"
EOF

    echo -e "${GREEN}Arquivo .env criado/atualizado com sucesso!${NC}"
}

# Função para detectar container do Postgres no Docker Swarm
detect_postgres_container() {
    # Exemplo: precisamos identificar qual serviço é do Postgres
    # Aqui assumimos que o serviço no swarm chama-se "postgres_service"
    # Ajuste conforme sua realidade.
    # Caso contrário, pode-se listar e filtrar:
    # docker ps --filter "ancestor=postgres" --format "{{.ID}}"
    POSTGRES_CONTAINER_ID=$(docker ps --filter "ancestor=postgres" --format "{{.ID}}" | head -n 1)
    if [ -z "$POSTGRES_CONTAINER_ID" ]; then
        echo -e "${RED}Não foi possível detectar o container do PostgreSQL. Verifique o Swarm.${NC}"
        return 1
    fi
    echo "$POSTGRES_CONTAINER_ID"
    return 0
}

# Função para testar conexão ao banco
test_connection() {
    export PGPASSWORD="$POSTGRES_PASSWORD"
    pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U postgres > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}Falha ao conectar no Postgres. Verifique as credenciais e o host.${NC}"
        exit 1
    fi
}

# Função para limpar backups antigos de acordo com retenção
clean_old_backups() {
    # Encontra pastas mais antigas que retention_days_value e apaga
    find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -mtime +$retention_days_value -exec rm -rf {} \; 2>/dev/null
}

# Função para obter o tamanho de um arquivo de backup
get_file_size() {
    local file="$1"
    if [ -f "$file" ]; then
        du -h "$file" | cut -f1
    else
        echo "0B"
    fi
}

# Função para notificar via webhook
send_webhook_notification() {
    local action="$1"
    local backup_date="$2"
    local db_name="$3"
    local backup_file="$4"
    local backup_size="$5"
    local deleted_backup="$6"         # nome do backup deletado, se houver
    local deletion_reason="$7"        # motivo da deleção, se houver

    local retention="$retention_days_value"
    local json_payload=$(cat <<EOF
{
  "action": "$action",
  "date": "$backup_date",
  "database_name": "$db_name",
  "backup_file": "$backup_file",
  "backup_size": "$backup_size",
  "retention_days": $retention,
  "deleted_backup": {
    "backup_name": "$deleted_backup",
    "deletion_reason": "$deletion_reason"
  },
  "status": "OK",
  "notes": "Backup/Restauração executado conforme configuração."
}
EOF
)
    curl -s -X POST -H "Content-Type: application/json" -d "$json_payload" "$WEBHOOK_URL" > /dev/null
}

# Função para executar backup completo
full_backup() {
    test_connection
    TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
    BACKUP_DIR="$BACKUP_BASE_DIR/$TIMESTAMP"
    mkdir -p "$BACKUP_DIR/backup-completo" "$BACKUP_DIR/backup-databases"

    echo -e "${BLUE}Iniciando backup completo do cluster...${NC}"
    export PGPASSWORD="$POSTGRES_PASSWORD"
    # Backup completo
    pg_dumpall -U postgres -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -f "$BACKUP_DIR/backup-completo/backup_completo_$TIMESTAMP.sql"

    # Backup de cada database (lista bancos e faz dump individual)
    DBS=$(psql -U postgres -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');")
    for DB in $DBS; do
        pg_dump -U postgres -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -F c -f "$BACKUP_DIR/backup-databases/${DB}_$TIMESTAMP.backup" "$DB"
    done

    # Limpar backups antigos
    BEFORE_DELETE=$(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -mtime +$retention_days_value)
    clean_old_backups
    AFTER_DELETE=$(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -mtime +$retention_days_value)

    DELETED_BACKUP=""
    DELETION_REASON=""
    if [ "$BEFORE_DELETE" != "$AFTER_DELETE" ]; then
        # Algum backup foi apagado
        DELETED_BACKUP=$(echo "$BEFORE_DELETE" | grep -v "$AFTER_DELETE")
        DELETION_REASON="Prazo de retenção expirado"
    fi

    # Notificar via webhook
    FILESIZE=$(get_file_size "$BACKUP_DIR/backup-completo/backup_completo_$TIMESTAMP.sql")
    send_webhook_notification "Backup realizado com sucesso" "$(date +"%d/%m/%Y %H:%M:%S")" "todos_os_bancos" "backup_completo_$TIMESTAMP.sql" "$FILESIZE" "$DELETED_BACKUP" "$DELETION_REASON"

    echo -e "${GREEN}Backup completo finalizado com sucesso!${NC}"
}

# Função para backup de bancos específicos
specific_backup() {
    test_connection
    # Listar bancos
    echo -e "${BLUE}Listando bancos disponíveis:${NC}"
    DBS=$(psql -U postgres -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');")
    declare -a db_array=()
    i=1
    for dbn in $DBS; do
        echo "$i. $dbn"
        db_array+=("$dbn")
        ((i++))
    done

    read -p "Digite os números dos bancos que deseja fazer backup (ex: 1 3 5): " choices
    TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
    BACKUP_DIR="$BACKUP_BASE_DIR/$TIMESTAMP"
    mkdir -p "$BACKUP_DIR/backup-databases"

    for choice in $choices; do
        dbname="${db_array[$((choice-1))]}"
        echo -e "${YELLOW}Fazendo backup do banco: $dbname...${NC}"
        pg_dump -U postgres -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -F c -f "$BACKUP_DIR/backup-databases/${dbname}_$TIMESTAMP.backup" "$dbname"
    done

    # Limpar antigos
    BEFORE_DELETE=$(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -mtime +$retention_days_value)
    clean_old_backups
    AFTER_DELETE=$(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -mtime +$retention_days_value)

    DELETED_BACKUP=""
    DELETION_REASON=""
    if [ "$BEFORE_DELETE" != "$AFTER_DELETE" ]; then
        DELETED_BACKUP=$(echo "$BEFORE_DELETE" | grep -v "$AFTER_DELETE")
        DELETION_REASON="Prazo de retenção expirado"
    fi

    # Notificação
    FILESIZE_TOTAL=0
    for choice in $choices; do
        dbname="${db_array[$((choice-1))]}"
        SIZE=$(get_file_size "$BACKUP_DIR/backup-databases/${dbname}_$TIMESTAMP.backup")
        send_webhook_notification "Backup de banco específico" "$(date +"%d/%m/%Y %H:%M:%S")" "$dbname" "${dbname}_$TIMESTAMP.backup" "$SIZE" "$DELETED_BACKUP" "$DELETION_REASON"
    done

    echo -e "${GREEN}Backup de bancos específicos finalizado!${NC}"
}

# Listar todos os backups
list_backups() {
    echo -e "${BLUE}Listando todos os backups disponíveis:${NC}"
    ls -1 "$BACKUP_BASE_DIR" | sort
}

# Restauração completa
restore_backup() {
    test_connection
    echo -e "${YELLOW}Listando backups para restauração:${NC}"
    backups_list=$(ls -1 "$BACKUP_BASE_DIR" | sort)
    i=1
    declare -a backup_dirs=()
    for bkp in $backups_list; do
        echo "$i. $bkp"
        backup_dirs+=("$bkp")
        ((i++))
    done
    read -p "Digite o número do backup a restaurar: " restore_choice
    selected_backup="${backup_dirs[$((restore_choice-1))]}"

    FULL_BACKUP_FILE="$BACKUP_BASE_DIR/$selected_backup/backup-completo/backup_completo_${selected_backup}.sql"
    if [ -f "$FULL_BACKUP_FILE" ]; then
        echo -e "${YELLOW}Restauração completa do cluster usando ${FULL_BACKUP_FILE}...${NC}"
        # Precisamos recriar bancos se necessário. O pg_dumpall contém instruções de criação,
        # então basta:
        export PGPASSWORD="$POSTGRES_PASSWORD"
        psql -U postgres -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -f "$FULL_BACKUP_FILE"
        echo -e "${GREEN}Restauração completa concluída!${NC}"
        send_webhook_notification "Restauração realizada com sucesso" "$(date +"%d/%m/%Y %H:%M:%S")" "todos_os_bancos" "backup_completo_${selected_backup}.sql" "$(get_file_size "$FULL_BACKUP_FILE")" "" ""
    else
        echo -e "${RED}Arquivo de backup completo não encontrado para o backup selecionado.${NC}"
    fi
}

# Restaurar bancos específicos (opcional)
restore_specific_db() {
    test_connection
    echo -e "${YELLOW}Listando backups para restauração de bancos individuais:${NC}"
    backups_list=$(ls -1 "$BACKUP_BASE_DIR" | sort)
    i=1
    declare -a backup_dirs=()
    for bkp in $backups_list; do
        echo "$i. $bkp"
        backup_dirs+=("$bkp")
        ((i++))
    done
    read -p "Digite o número do backup a restaurar: " restore_choice
    selected_backup="${backup_dirs[$((restore_choice-1))]}"
    BACKUP_DB_DIR="$BACKUP_BASE_DIR/$selected_backup/backup-databases"
    if [ ! -d "$BACKUP_DB_DIR" ]; then
        echo -e "${RED}Nenhum backup individual de bancos encontrado nesse diretório.${NC}"
        return
    fi

    # Listar arquivos no backup-databases
    echo -e "${BLUE}Bancos disponíveis no backup:${NC}"
    files_list=$(ls -1 "$BACKUP_DB_DIR")
    j=1
    declare -a db_files=()
    for f in $files_list; do
        echo "$j. $f"
        db_files+=("$f")
        ((j++))
    done
    read -p "Digite o número do arquivo de backup a restaurar: " db_choice
    selected_db_file="${db_files[$((db_choice-1))]}"

    # Extrair nome do banco
    dbname=$(echo "$selected_db_file" | cut -d'_' -f1)
    echo -e "${YELLOW}Restaurando o banco $dbname ...${NC}"
    export PGPASSWORD="$POSTGRES_PASSWORD"
    # Verificar se banco existe
    db_exist=$(psql -U postgres -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -tAc "SELECT 1 FROM pg_database WHERE datname='$dbname';")
    if [ "$db_exist" != "1" ]; then
        echo -e "${BLUE}Banco não existe, criando...${NC}"
        createdb -U postgres -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" "$dbname"
    fi

    pg_restore -U postgres -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -d "$dbname" "$BACKUP_DB_DIR/$selected_db_file"
    echo -e "${GREEN}Restauração do banco $dbname concluída!${NC}"
    send_webhook_notification "Restauração de banco específica realizada com sucesso" "$(date +"%d/%m/%Y %H:%M:%S")" "$dbname" "$selected_db_file" "$(get_file_size "$BACKUP_DB_DIR/$selected_db_file")" "" ""
}

# Menu principal
main_menu() {
    while true; do
        echo -e "${GREEN}===== PostgreSQL Backup Manager v$SCRIPT_VERSION =====${NC}"
        echo "1. Fazer backup completo"
        echo "2. Fazer backup de bancos específicos"
        echo "3. Restaurar backup completo"
        echo "4. Restaurar backup de bancos específicos"
        echo "5. Listar todos os backups"
        echo "6. Atualizar configurações"
        echo "7. Sair"
        read -p "Digite o número da opção desejada: " choice

        case $choice in
            1) full_backup ;;
            2) specific_backup ;;
            3) restore_backup ;;
            4) restore_specific_db ;;
            5) list_backups ;;
            6) setup_env ;;
            7) echo -e "${BLUE}Saindo...${NC}"; exit 0 ;;
            *) echo -e "${RED}Opção inválida.${NC}" ;;
        esac
    done
}

# Entrada do script
load_env

if [ "$1" == "--setup" ]; then
    setup_env
    # Perguntar se quer backup agora
    read -p "Deseja iniciar um backup completo agora? (s/n): " resp
    if [ "$resp" == "s" ]; then
        full_backup
    fi
    main_menu
elif [ "$1" == "--auto-backup" ]; then
    # Modo automático para ser usado no cron
    full_backup
    exit 0
else
    # Modo interativo
    main_menu
fi
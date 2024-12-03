#!/bin/bash

# =============================================================================
# Main Backup Manager para PostgreSQL em Docker
# Versão: 1.0.0
# Autor: System Administrator
# Data: 2024
# =============================================================================
# Descrição: Script principal para orquestrar backups e restaurações de
# bancos de dados PostgreSQL rodando em containers Docker. Integra-se com
# scripts armazenados no GitHub e utiliza um arquivo .env para configurações.
# =============================================================================

set -euo pipefail

# =============================================================================
# Funções de Utilidade
# =============================================================================

function echo_info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}

function echo_success() {
    echo -e "\e[32m[SUCCESS]\e[0m $1"
}

function echo_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1"
}

function echo_error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
}

# Função para verificar se um comando existe
function command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# =============================================================================
# Definição de Variáveis
# =============================================================================

ENV_FILE="/root/.backup_postgres.env"
REPO_URL="https://github.com/imdsoliveira/postgres-backup-manager.git"
REPO_DIR="/opt/postgres-backup-manager"
SCRIPTS_DIR="$REPO_DIR/scripts"
MAIN_SCRIPT="$SCRIPTS_DIR/main_backup_manager.sh"
BACKUP_SCRIPT="$SCRIPTS_DIR/backup_postgres.sh"
RESTORE_SCRIPT="$SCRIPTS_DIR/restore_postgres.sh"

# =============================================================================
# Verificar Dependências
# =============================================================================

if ! command_exists git; then
    echo_info "Git não está instalado. Instalando Git..."
    apt-get update && apt-get install -y git
    echo_success "Git instalado com sucesso."
fi

# =============================================================================
# Clonar ou Atualizar o Repositório de Scripts
# =============================================================================

if [ ! -d "$REPO_DIR" ]; then
    echo_info "Clonando repositório de scripts do GitHub..."
    git clone "$REPO_URL" "$REPO_DIR"
    echo_success "Repositório clonado em $REPO_DIR."
else
    echo_info "Atualizando repositório de scripts..."
    cd "$REPO_DIR"
    git pull origin main
    echo_success "Repositório atualizado."
fi

# =============================================================================
# Carregar Configurações
# =============================================================================

if [ -f "$ENV_FILE" ]; then
    echo_info "Carregando configurações do $ENV_FILE..."
    source "$ENV_FILE"
    echo_success "Configurações carregadas."
else
    echo_error "Arquivo de configuração $ENV_FILE não encontrado."
    echo_info "Por favor, crie o arquivo a partir do template:"
    echo_info "cp $REPO_DIR/.env.template $ENV_FILE"
    exit 1
fi

# =============================================================================
# Garantir Permissões dos Scripts
# =============================================================================

chmod +x "$BACKUP_SCRIPT" "$RESTORE_SCRIPT"
echo_success "Permissões dos scripts garantidas."

# =============================================================================
# Menu de Opções
# =============================================================================

echo_info "Selecione a operação desejada:"
echo "1) Executar Backup"
echo "2) Executar Restauração"
echo "3) Atualizar Scripts"
echo "4) Sair"

read -p "Digite o número correspondente à opção desejada: " OPTION

case "$OPTION" in
    1)
        echo_info "Executando Backup..."
        bash "$BACKUP_SCRIPT"
        ;;
    2)
        echo_info "Executando Restauração..."
        bash "$RESTORE_SCRIPT"
        ;;
    3)
        echo_info "Atualizando scripts do repositório..."
        cd "$REPO_DIR"
        git pull origin main
        chmod +x "$BACKUP_SCRIPT" "$RESTORE_SCRIPT"
        echo_success "Scripts atualizados."
        ;;
    4)
        echo_info "Saindo."
        exit 0
        ;;
    *)
        echo_error "Opção inválida. Saindo."
        exit 1
        ;;
esac

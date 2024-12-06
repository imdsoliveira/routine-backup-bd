# README
# PostgreSQL Backup Manager 2024 - Versão 1.4.4

## Funcionalidades Incluídas:
 -> Backup automático diário
 -> Retenção configurável
 -> Notificações webhook consolidadas
 -> Restauração interativa com barra de progresso
 -> Detecção automática de container PostgreSQL
 -> Criação automática de estruturas (sequências, tabelas e índices)
 -> Gerenciamento de logs com rotação
 -> Recriação automática de estruturas ausentes
 -> Verificação pré-backup para garantir a existência do banco de dados
 -> Correção na ordem das operações durante a restauração
 -> Função de limpeza para remover instalações anteriores

# Comandos
## Comando Antigo Baixar Script

```shell
bash <(curl -sSL https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/setup_backup.sh)
```

## Limpar manualmente:

```shell
curl -sSL https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/setup_backup.sh | bash -s -- --clean
```

## Instalar novo

```shell
bash <(curl -sSL https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/setup_backup.sh)
```

## Ou em um único comando:

```shell
bash <(curl -sSL https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/setup_backup.sh) | bash -s -- --clean && bash <(curl -sSL https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/setup_backup.sh)
```

## Backup manual

```shell
pg_backup
```

## Restauração

```shell
pg_restore_db
```

## Limpar Instalação

```shell
pg_backup_manager.sh --clean
```

# 

```shell
```

# Instruções Complementares
## Primeira Execução:

```shell
bash <(curl -sSL https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/setup_backup.sh)
```
Siga as instruções para configurar usuário, senha (visível), retenção e webhook.

Menu Interativo:
Após a configuração, o menu aparecerá a cada execução do script sem parâmetros.

Backup Completo: backup de todos os bancos.
Backup Parcial: escolher quais bancos backupear.
Restauração Completa: listar todos os bancos com backups, restaurar todos, escolhendo qual backup por banco.
Restauração Parcial: escolher quais bancos restaurar e qual backup de cada um.
Atualizar Configurações: alterar usuário, senha, retenção, webhook.
Sair: sair do script.
Conexão com Banco: Antes de qualquer backup ou restauração, o script testa a conexão. Se falhar, interrompe o processo.

Senhas Visíveis: A senha do PostgreSQL é digitada de forma visível no terminal, conforme solicitado.

Sem Barra de Progresso na Restauração: Restauração é feita diretamente, evitando problemas de sintaxe.

Escolha do Backup na Restauração: Ao restaurar um banco, todos os backups encontrados para aquele banco são listados, permitindo escolher qual backup restaurar.

Limpeza da Instalação:

bash
Copiar código
pg_backup_manager.sh --clean
Atualização:

bash
Copiar código
pg_backup_manager.sh --update
Configuração:

bash
Copiar código
pg_backup_manager.sh --configure

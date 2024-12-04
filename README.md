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
curl -sSL https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/setup_backup.sh | bash -s -- --clean && bash <(curl -sSL https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/setup_backup.sh)
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


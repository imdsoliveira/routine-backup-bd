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


Para visualizar os backups diretamente pelo terminal, você pode usar comandos do próprio sistema operacional Linux para listar os arquivos presentes no diretório de backups. Por exemplo:

1. **Listar todos os backups com detalhes**:  
   ```bash
   ls -lh /var/backups/postgres
   ```
   Esse comando irá mostrar todos os arquivos no diretório `/var/backups/postgres` com tamanho e permissões.

2. **Filtrar apenas os backups**:  
   Caso você queira listar apenas arquivos que seguem o padrão de nome (`postgres_backup_...`), pode usar:
   ```bash
   ls -lh /var/backups/postgres/postgres_backup_*.sql.gz
   ```

3. **Mostrar data, tamanho e nome em ordem cronológica**:  
   Se quiser ver em ordem de data (mais recentes primeiro):
   ```bash
   ls -ltlh /var/backups/postgres/postgres_backup_*.sql.gz
   ```

4. **Usar `find` para pesquisar backups**:  
   ```bash
   find /var/backups/postgres -name "postgres_backup_*.sql.gz" -ls
   ```
   Esse comando mostra os arquivos encontrados com detalhes (tamanho, data, etc.).

Basicamente, basta navegar até o diretório de backups (`/var/backups/postgres`) e usar comandos padrão do Linux, como `ls` e `find`, para visualizar os arquivos de backup disponíveis.


Para visualizar os backups diretamente pelo terminal, você pode usar comandos do próprio sistema operacional Linux para listar os arquivos presentes no diretório de backups. Por exemplo:

1. **Listar todos os backups com detalhes**:  
   ```bash
   ls -lh /var/backups/postgres
   ```
   Esse comando irá mostrar todos os arquivos no diretório `/var/backups/postgres` com tamanho e permissões.

2. **Filtrar apenas os backups**:  
   Caso você queira listar apenas arquivos que seguem o padrão de nome (`postgres_backup_...`), pode usar:
   ```bash
   ls -lh /var/backups/postgres/postgres_backup_*.sql.gz
   ```

3. **Mostrar data, tamanho e nome em ordem cronológica**:  
   Se quiser ver em ordem de data (mais recentes primeiro):
   ```bash
   ls -ltlh /var/backups/postgres/postgres_backup_*.sql.gz
   ```

4. **Usar `find` para pesquisar backups**:  
   ```bash
   find /var/backups/postgres -name "postgres_backup_*.sql.gz" -ls
   ```
   Esse comando mostra os arquivos encontrados com detalhes (tamanho, data, etc.).

Basicamente, basta navegar até o diretório de backups (`/var/backups/postgres`) e usar comandos padrão do Linux, como `ls` e `find`, para visualizar os arquivos de backup disponíveis.


## Instruções

- **Primeira Execução**:  
  ```bash
  bash <(curl -sSL https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/setup_backup.sh)
  ```
  O script solicitará usuário, senha visível, dias de retenção e URL do webhook, além de detectar o container do PostgreSQL.

- **Menu Interativo**:  
  Após a configuração, um menu aparecerá com as seguintes opções:
  1. Fazer backup completo
  2. Fazer backup de bancos específicos
  3. Restaurar backup completo
  4. Restaurar backup de bancos específicos
  5. Atualizar configurações
  6. Sair
  7. Listar todos os backups

- **Listar Todos os Backups**:  
  Na opção "7", serão exibidos todos os arquivos de backup encontrados no diretório `/var/backups/postgres`, com data e tamanho, para controle e verificação.

- **Logs Aprimorados**:  
  Mensagens informativas (INFO) agora aparecem em azul, sucesso (SUCCESS) em verde, warnings em amarelo e erros em vermelho. Além disso, mais mensagens detalhadas sobre o andamento do backup/restauração são exibidas.

- **Limpeza da Instalação**:
  ```bash
  pg_backup_manager.sh --clean
  ```

- **Atualização**:
  ```bash
  pg_backup_manager.sh --update
  ```

- **Reconfiguração**:
  ```bash
  pg_backup_manager.sh --configure
  ```

- **Correção na Restauração**:  
  Durante a restauração, se o usuário digitar um número inválido ao selecionar o backup, uma mensagem de erro será exibida e o script solicitará novamente a entrada. O usuário pode digitar '0' para cancelar a restauração do banco de dados atual.
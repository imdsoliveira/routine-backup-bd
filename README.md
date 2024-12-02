# Routine Backup BD

**Rotina de backup de banco de dados PostgreSQL com opção de restauração**

## Visão Geral

O **Routine Backup BD** é uma solução automatizada para realizar backups periódicos de bancos de dados PostgreSQL em ambientes Dockerizados. Além da criação automática de backups, o sistema oferece opções de restauração e notificações via webhook para monitoramento em tempo real.

---

## Requisitos

Antes de iniciar a configuração, certifique-se de que os seguintes componentes estejam instalados e configurados no seu servidor:

- **Docker:** Plataforma para desenvolvimento, envio e execução de aplicativos em containers.
- **PostgreSQL:** Sistema de gerenciamento de banco de dados relacional.
- **pg_dump:** Utilitário para exportar bancos de dados PostgreSQL.
- **Cron:** Agendador de tarefas para executar scripts automaticamente.
- **cURL:** Ferramenta para transferir dados com URLs, utilizada para enviar notificações via webhook.

### Verificações Necessárias

1. **Verificar pg_dump:**

    ```bash
    pg_dump --version
    ```

2. **Verificar Cron:**

    ```bash
    crontab -l
    systemctl status cron
    ```

3. **Verificar cURL:**

    ```bash
    curl --version
    ```

## Configuração Inicial

### 1. Preparação do Ambiente

Antes de executar o script de configuração, realize os seguintes passos:

- **Criar o Diretório de Backups:**

    Crie um diretório dedicado para armazenar os backups do PostgreSQL.

    ```bash
    sudo mkdir -p /var/backups/postgres
    sudo chown root:root /var/backups/postgres 
    sudo chmod 700 /var/backups/postgres
    ```

### 2. Montagem do Diretório de Backups no Container

Para garantir que os backups sejam armazenados corretamente no host, o diretório de backups deve ser montado no container PostgreSQL.

- **Adicionar Volume no Docker Compose:**

    Edite o arquivo `docker-compose.yml` do seu container PostgreSQL para incluir o volume de backup.

    ```yaml
    volumes:
      - /var/backups/postgres:/var/backups/postgres
    ```

- **Reiniciar o Container:**

    Após adicionar o volume, reinicie o container para aplicar as mudanças.

    ```bash
    docker-compose down
    docker-compose up -d
    ```

- **Verificar a Montagem do Volume:**

    ```bash
    docker inspect -f '{{ range .Mounts }}{{ if eq .Destination "/var/backups/postgres" }}{{ .Source }}{{ end }}{{ end }}' nome_do_container
    ```

---

## Instalação e Configuração

### 1. Executando o Script de Configuração

Execute o script de configuração para automatizar a criação dos scripts de backup e restauração, além de configurar o agendamento com o cron.

```bash
bash <(curl -sSL https://raw.githubusercontent.com/imdsoliveira/routine-backup-bd/main/setup_backup.sh)
```

Durante a execução, você será solicitado a fornecer as seguintes informações:

- **Nome do Container PostgreSQL:** O script tenta identificar automaticamente, mas pode ser solicitado que você insira manualmente caso haja múltiplos containers ou nenhum identificado.
- **Usuário do PostgreSQL:** Por padrão, é `postgres`. Você pode optar por usar o usuário padrão ou especificar outro.
- **Senha do Usuário PostgreSQL:** Insira a senha do usuário selecionado.
- **Período de Retenção dos Backups:** Número de dias que os backups serão mantidos (padrão: 30 dias).
- **URL do Webhook para Notificações:** Insira a URL completa do seu serviço de webhook para receber notificações (exemplo: Discord, Slack).

### 2. Configurando Autenticação Automática

O script de configuração cria e configura o arquivo `.pgpass` para autenticação automática com o PostgreSQL, evitando a necessidade de inserir a senha manualmente durante os backups.

- **Localização do Arquivo `.pgpass`:**

    ```bash
    /root/.pgpass
    ```

- **Permissões do Arquivo:**

    ```bash
    chmod 600 /root/.pgpass
    ```

### 3. Configurando Notificações via Webhook

Após configurar o backup, o sistema enviará notificações via webhook informando sobre o status dos backups.

- **Verifique a Recepção das Notificações:**

    Certifique-se de que o serviço de webhook está recebendo as notificações corretamente. Teste manualmente a URL do webhook, se necessário.

    ```bash
    curl -X POST -H "Content-Type: application/json" -d '{"test": "backup"}' "https://seu-webhook-url.com/webhook"
    ```

---

## Operações Manuais

### 1. Executando o Backup Manualmente

Para executar o backup manualmente, utilize o seguinte comando:

```bash
sudo /usr/local/bin/backup_postgres.sh
```

**Passos:**

1. **Executar o Script:**

    ```bash
    sudo /usr/local/bin/backup_postgres.sh
    ```

2. **Verificar a Criação do Backup:**

    ```bash
    ls -lh /var/backups/postgres/
    ```

    Você deve ver um novo arquivo de backup com o formato `postgres_backup_YYYYMMDDHHMMSS.backup`.

3. **Verificar os Logs de Backup:**

    ```bash
    cat /var/log/backup_postgres.log
    ```

    **Exemplo de Entrada de Log:**

    ```
    [2024-12-03 00:00:01] Backup OK: postgres_backup_20241203000000.backup, Size: 15M
    [2024-12-03 00:00:01] Backups antigos removidos: []
    ```

### 2. Restaurando um Backup Manualmente

Para restaurar um backup, utilize o script de restauração fornecido.

```bash
sudo /usr/local/bin/restore_postgres.sh
```

**Passos:**

1. **Executar o Script de Restauração:**

    ```bash
    sudo /usr/local/bin/restore_postgres.sh
    ```

2. **Selecionar o Backup para Restaurar:**

    O script listará todos os backups disponíveis. Digite o número correspondente ao backup que deseja restaurar.

3. **Confirmar a Restauração:**

    Confirme que deseja restaurar o backup selecionado. **Atenção:** Isso sobrescreverá o banco de dados atual.

4. **Verificar os Logs de Restauração:**

    ```bash
    cat /var/log/backup_postgres.log
    ```

    **Exemplo de Entrada de Log:**

    ```
    [2024-12-03 00:10:00] Restauração OK: postgres_backup_20241203000000.backup
    ```

### 3. Removendo Arquivos de Backup Manualmente

Para remover backups manualmente da pasta de backups, siga os passos abaixo.

1. **Listar os Backups Existentes:**

    ```bash
    ls -lh /var/backups/postgres/
    ```

2. **Remover Backups Específicos:**

    Para remover todos os backups com a extensão `.backup`:

    ```bash
    sudo rm /var/backups/postgres/*.backup
    ```

    **Remover Apenas Backups com Tamanho Zero:**

    ```bash
    sudo find /var/backups/postgres/ -type f -size 0 -name "*.backup" -exec rm {} \;
    ```

3. **Confirmar a Remoção dos Backups:**

    ```bash
    ls -lh /var/backups/postgres/
    ```

    O diretório deve estar limpo ou conter apenas os backups que você deseja manter.

---

## Automatização com Cron

O script de configuração já adiciona uma entrada no `crontab` para executar o backup automaticamente todos os dias às 00:00.

### Verificar o Cron Job

1. **Listar Cron Jobs:**

    ```bash
    crontab -l
    ```

    **Saída Esperada:**

    ```
    0 0 * * * /usr/local/bin/backup_postgres.sh >> /var/log/backup_postgres_cron.log 2>&1
    ```

2. **Verificar o Serviço Cron:**

    Certifique-se de que o serviço cron está ativo e funcionando.

    ```bash
    systemctl status cron
    ```

    **Saída Esperada:**

    ```
    ● cron.service - Regular background program processing daemon
       Loaded: loaded (/lib/systemd/system/cron.service; enabled; vendor preset: enabled)
       Active: active (running) since Thu 2024-12-02 12:00:00 UTC; 2h ago
    ```

3. **Verificar os Logs do Cron Job Após a Execução Agendada:**

    Após o próximo horário agendado, verifique os logs para confirmar a execução do backup automático.

    ```bash
    cat /var/log/backup_postgres_cron.log
    ```

    **Exemplo de Entrada de Log:**

    ```
    [2024-12-03 00:00:01] Backup OK: postgres_backup_20241203000000.backup, Size: 15M
    [2024-12-03 00:00:01] Backups antigos removidos: []
    ```

---

## Monitoramento e Logs

### Logs de Backup

Os logs de backup são armazenados em:

```bash
/var/log/backup_postgres.log
```

**Conteúdo do Log:**

```
[2024-12-03 00:00:01] Backup OK: postgres_backup_20241203000000.backup, Size: 15M
[2024-12-03 00:00:01] Backups antigos removidos: []
```

### Logs do Cron Job

Os logs das execuções automáticas do cron job são armazenados em:

```bash
/var/log/backup_postgres_cron.log
```

**Conteúdo do Log:**

```
[2024-12-03 00:00:01] Backup OK: postgres_backup_20241203000000.backup, Size: 15M
[2024-12-03 00:00:01] Backups antigos removidos: []
```

### Notificações via Webhook

As notificações de backup e restauração são enviadas para a URL do webhook configurada. Verifique no seu serviço de webhook (como Discord ou Slack) se as mensagens estão sendo recebidas conforme esperado.

---

## Boas Práticas e Considerações de Segurança

### Proteção das Credenciais

- **Arquivo `.pgpass`:** Certifique-se de que este arquivo está protegido com permissões restritivas (`600`).

    ```bash
    ls -l /root/.pgpass
    ```

    **Saída Esperada:**

    ```
    -rw------- 1 root root 42 Dez  3 00:00 /root/.pgpass
    ```

- **Scripts de Backup e Restauração:** Mantenha os scripts em locais seguros e assegure que apenas usuários autorizados tenham acesso a eles.

### Monitoramento Contínuo

- **Logs de Backup:** Monitore regularmente os logs em `/var/log/backup_postgres.log` e `/var/log/backup_postgres_cron.log` para identificar possíveis falhas ou problemas.
- **Notificações:** Utilize as notificações via webhook para receber alertas em tempo real sobre o status dos backups.

### Testes Periódicos de Restauração

Realize testes regulares de restauração para garantir que os backups estão íntegros e funcionais.

```bash
sudo /usr/local/bin/restore_postgres.sh
```

**Observação:** Execute esses testes em um ambiente de staging ou desenvolvimento para evitar impactos na produção.

### Atualizações e Manutenção dos Scripts

- **Atualizações do PostgreSQL/Docker:** Mantenha o PostgreSQL e o Docker atualizados para garantir a segurança e o bom funcionamento dos backups.
- **Revisão dos Scripts:** Periodicamente, revise e atualize os scripts para incorporar melhorias e correções de segurança.

### Armazenamento Remoto e Redundância

- **Backups Remotos:** Considere armazenar backups em locais remotos ou serviços de armazenamento na nuvem para garantir maior segurança e redundância.
- **Redundância:** Mantenha múltiplas cópias dos backups em diferentes locais físicos ou lógicos.

---

## FAQ

**1. O que fazer se os backups estiverem sendo criados com tamanho zero ou muito pequeno?**

- **Verifique a Configuração do Webhook:** Certifique-se de que a URL do webhook está correta no script de backup.
- **Permissões:** Confirme se o diretório de backups está corretamente montado no container PostgreSQL e que o usuário `postgres` tem permissões para escrever nesse diretório.
- **Teste Manual do Backup:** Execute o script de backup manualmente e verifique os logs para identificar possíveis erros.

**2. Como adicionar mais usuários para realizar backups?**

- **Editar o Arquivo `.pgpass`:** Adicione entradas adicionais para cada usuário no formato:

    ```
    localhost:5432:postgres:usuario:sua_senha
    ```

- **Modificar o Script de Backup:** Atualize o script para incluir os novos usuários conforme necessário.

**3. Como restaurar um backup em um ambiente diferente?**

- **Transferir o Arquivo de Backup:** Copie o arquivo de backup para o novo ambiente.
- **Executar o Script de Restauração:** Utilize o script de restauração manualmente, especificando o caminho correto para o arquivo de backup.

---

## Suporte

Para suporte adicional ou dúvidas específicas sobre a configuração e uso da rotina de backup, entre em contato:

- **Email:** suporte@seudominio.com
- **GitHub Issues:** [Routine Backup BD Issues](https://github.com/imdsoliveira/routine-backup-bd/issues)
- **Documentação Adicional:** Consulte os documentos oficiais do [PostgreSQL](https://www.postgresql.org/docs/) e do [Docker](https://docs.docker.com/).

---

**Agradecemos por utilizar o Routine Backup BD!**
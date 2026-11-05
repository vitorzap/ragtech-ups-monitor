# Proteção elétrica automatizada — Ragtech, NUT, QNAP e Mac mini

**Documentação técnica sanitizada | versão para compartilhamento**  
**Estado:** implantação funcional validada em teste físico de falta de energia e reinicialização.  
**Escopo restrito:** nobreak Ragtech USB, driver personalizado, servidor NUT em container, automação de desligamento no QNAP e receptor no Mac mini.

> **Privacidade:** esta versão omite endereços IP reais, nomes de usuários, números de série, identificadores específicos do ambiente, serviços Docker não relacionados, caminhos absolutos internos do proprietário, chaves, senhas e logs que possam revelar a infraestrutura. Os exemplos usam variáveis e marcadores (`<...>`). Não publique os arquivos de configuração originais sem revisá-los e remover segredos.
>
> **Fidelidade:** a documentação descreve os componentes, parâmetros e comportamentos confirmados. O Dockerfile completo, código-fonte integral do driver e parte das configurações finais não foram recuperados integralmente para esta documentação; por isso, não são apresentados como receitas completas de reconstrução.

## 1. Visão geral

O nobreak alimenta temporariamente os equipamentos durante uma falha elétrica. Sua interface USB é conectada ao NAS QNAP, onde um **driver Ragtech personalizado** executado em um **container Docker** fornece dados ao **Network UPS Tools (NUT)**. Um monitor independente no host QNAP lê os estados do NUT e aplica uma política de desligamento coordenado:

- **Após 30 segundos** de falta contínua de energia (`OB`): solicita o desligamento do **Mac mini** via SSH.
- **Após 60 segundos**: solicita o desligamento do **QNAP**.
- **Bateria crítica (`OB LB`)**: antecipa a solicitação dos desligamentos.
- **Retorno da energia (`OL`) antes de uma ação**: cancela as ações ainda pendentes e reinicia os contadores.

Os temporizadores definem o início das solicitações, **não** o tempo total necessário para encerrar o sistema operacional e desmontar volumes.

### Arquitetura

```text
Nobreak Ragtech (USB)
       │
       ▼
QNAP — container Docker dedicado
       ├─ Driver Ragtech personalizado
       └─ NUT (driver + upsd)
                 │
       TCP/IP na rede local
                 │
       ├── Clientes NUT de monitoramento
       │
       ▼
QNAP — monitor de eventos V4
       ├── Falha de energia por 30 s
       │     └─ SSH autenticado/restrito → receptor no Mac mini
       │                                      └─ shutdown -h now
       └── Falha de energia por 60 s
             └─ verificação de estado → sync → poweroff

QNAP — rotina de inicialização
       └─ supervisor → mantém monitor V4 ativo
```

## 2. Construção do container e do driver Ragtech

### 2.1. Interface USB

O nobreak apresentou interface **USB serial CDC ACM**, exposta no Linux como um dispositivo do tipo `/dev/ttyACM*`. A implementação utilizou o dispositivo reconhecido pelo QNAP, sem presumir compatibilidade com drivers USB HID genéricos.

Para uma nova instalação, identifique a interface USB real do equipamento e mantenha o mapeamento de dispositivo coerente com o Docker Compose. **Identificadores de dispositivo USB e números de série não são reproduzidos aqui**, pois não são necessários para explicar a arquitetura.

### 2.2. Driver específico

Foi empregado um **driver Ragtech experimental personalizado, versão 0.10**, em ambiente NUT da série **2.8.x**, compilado e incluído em uma imagem Docker própria. A imagem resultante permite que o NUT consulte o nobreak por sua interface serial USB.

Durante o desenvolvimento, o driver pôde ser invocado em modo diagnóstico com uma estrutura como:

```sh
export NUT_STATEPATH=/run/nut
<diretorio-de-instalacao>/bin/ragtech -a <nome-ups> -u root -d 2 -D
```

Esse comando é **apenas ilustrativo para diagnóstico**. Não deve ser executado em paralelo com o driver de produção. Para reconstruir a imagem é indispensável preservar os arquivos originais de build e o código-fonte do driver.

### 2.3. Elementos necessários no serviço Docker

O serviço dedicado ao NUT precisa contemplar:

- Imagem contendo o driver Ragtech compilado e componentes NUT.
- Acesso ao dispositivo USB serial do host QNAP.
- Configuração de identificação do nobreak (`ups.conf`).
- Serviço NUT `upsd` e sua configuração de rede/autenticação.
- Diretórios de estado e permissões compatíveis com o driver.
- Política de reinício adequada após reinicialização do NAS (por exemplo, `restart: unless-stopped`, quando apropriado).
- Exposição da porta NUT, normalmente **TCP 3493**, apenas para clientes autorizados da rede local.

> Não há aqui um `docker-compose.yml` completo fiel à instalação, porque suas definições finais integrais não foram fornecidas. O serviço NUT deve ser documentado de forma isolada, sem expor nem listar outros containers do host.

## 3. Configuração NUT e leitura do nobreak

O nobreak foi registrado no NUT com um **nome lógico de serviço**. No host QNAP, a consulta utiliza o cliente `upsc`:

```sh
/sbin/upsc <nome-ups>@127.0.0.1:3493 ups.status
/sbin/upsc <nome-ups>@127.0.0.1:3493
```

Estados importantes:

| Estado | Interpretação |
|---|---|
| `OL` | Alimentação da rede presente |
| `OB` | Operação pela bateria |
| `LB` | Indicação de bateria baixa |
| `OL CHRG`, `OB DISCHRG` etc. | Combinações de indicadores NUT |
| `OFFLINE` | Comunicação com NUT indisponível, tratada separadamente pelo monitor |

O driver utilizado **não fornecia uma estimativa confiável de autonomia (`battery.runtime`)**. Assim, os tempos de 30 e 60 segundos são parâmetros operacionais e não garantias de que haverá bateria suficiente sob toda carga.

## 4. Organização dos scripts no host QNAP

Os scripts foram mantidos em um diretório persistente, representado aqui por:

```sh
UPS_DIR="<diretorio-persistente-do-projeto-ups>"
```

| Arquivo | Responsabilidade |
|---|---|
| `qnap-ups-events.sh` | Monitor V4; consulta o NUT, controla os tempos e dispara ações |
| `qnap-ups-action.sh` | Executa a solicitação ao Mac mini ou o desligamento do QNAP |
| `qnap-ups-events-watch.sh` | Supervisiona e reinicia o monitor V4, quando necessário |
| `qnap-upsmon-start.sh` | Integra inicialização do QNAP, espera o NUT e inicia supervisão |
| `enable-real-shutdown` | Chave operacional de ativação das ações reais |
| `ssh/<chave-privada-dedicada>` | Chave SSH do fluxo QNAP → Mac mini, mantida somente no host |
| `ssh/known_hosts` | Verificação da identidade SSH do Mac mini |
| `logs/` ou diretório equivalente | Registros do monitor, ações e supervisor |

**Observação:** o diretório real dos logs pode ter nome diferente. A documentação pública não precisa divulgar seu caminho absoluto.

### 4.1. Monitor de eventos V4

Parâmetros confirmados:

```sh
MAC_DELAY=30
QNAP_DELAY=60
EMERGENCY_GRACE=0
INTERVAL=5
RETRY_INTERVAL=10
```

Regras principais:

1. Consulta o status do NUT a cada aproximadamente 5 segundos.
2. Ao detectar `OB`, inicia o contador da falta de energia.
3. Solicita o desligamento do Mac mini após 30 segundos.
4. Solicita o desligamento do QNAP após 60 segundos.
5. Se detectar bateria baixa com a energia ausente, antecipa o acionamento.
6. Se detectar `OL` antes de disparar uma ação, zera os temporizadores e cancela o que ainda não foi iniciado.
7. Em `OFFLINE`, não presume automaticamente uma falta de energia; isso é uma **limitação conhecida da política atual**.

### 4.2. Evitar que o SSH bloqueie o desligamento do QNAP

Uma correção importante da implementação foi lançar a ação SSH do Mac mini em segundo plano. Sem isso, o encerramento da conexão durante o desligamento do Mac poderia bloquear o loop e atrasar a ordem de desligamento do QNAP.

**Padrão conceitual da chamada assíncrona:**

```sh
(
  "$UPS_DIR/qnap-ups-action.sh" mac </dev/null \
    >>"$UPS_DIR/<arquivo-de-log-de-acoes>" 2>&1 &
)
```

A continuação do monitor após o lançamento assíncrono **não prova que a ação remota teve sucesso**. O resultado SSH deve ser registrado separadamente pelo controlador.

### 4.3. Controlador de ações

O controlador possui dois caminhos, `mac` e `qnap`:

**Mac mini:** envia `ups-shutdown` por SSH usando chave específica, verificação rígida de host, conexão não interativa e prazo curto de conexão.

```sh
ssh -i "$SSH_KEY" \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$KNOWN_HOSTS" \
  -o ConnectTimeout=5 \
  -o ConnectionAttempts=1 \
  <usuario-mac>@<ip-mac-mini> ups-shutdown
```

**QNAP:** relê o estado do NUT e somente solicita o desligamento local se ainda houver indicação de bateria (`OB` ou `LB`):

```sh
STATUS=$(/sbin/upsc <nome-ups>@127.0.0.1:3493 ups.status 2>/dev/null)
case " $STATUS " in
  *" OB "*|*" LB "*)
    sync
    /sbin/poweroff
    ;;
  *)
    exit 1
    ;;
esac
```

**Atenção:** este trecho descreve um mecanismo que já foi validado em teste físico, mas invocar `/sbin/poweroff` manualmente provoca desligamento real. Não o utilize como teste de leitura.

A existência do arquivo `enable-real-shutdown` habilita as ações reais no controlador observado; sua ausência faz com que o controlador registre uma simulação. A ativação deve ser tratada como uma mudança operacional crítica.

## 5. Supervisão e inicialização automática no QNAP

### 5.1. Supervisor do monitor

O `qnap-ups-events-watch.sh` mantém **uma instância do monitor V4**, usando diretório-trava no host e um loop que relança o monitor se ele terminar. As ações principais são:

- Criar trava para impedir supervisores duplicados.
- Verificar se já existe monitor.
- Iniciar `qnap-ups-events.sh` com redirecionamento dos registros.
- Aguardar seu encerramento e reiniciar após intervalo controlado.
- Liberar a trava no encerramento normal do supervisor.

Não dependa de comandos como `nohup` ou `setsid` sem conferir sua disponibilidade na versão QTS instalada. Na implantação, a execução direta por `/bin/sh ... &` funcionou, e a recuperação automática foi demonstrada após reinicialização do NAS.

### 5.2. Autorun do QTS

O QNAP utiliza um mecanismo de execução automática na inicialização que invoca `qnap-upsmon-start.sh`. Esse script aguarda a disponibilidade dos serviços necessários e inicia a supervisão do monitor de eventos.

Pontos de atenção na manutenção:

- Evitar **duas chamadas** ao supervisor no mesmo script de inicialização.
- Não iniciar o monitor antes de o servidor NUT estar acessível.
- Garantir que o diretório de scripts seja persistente entre reinicializações.
- Preservar a configuração do autorun e suas permissões.

Também foi usado um `upsmon` nativo do QNAP com configuração independente e comando de desligamento **não operacional** (`SHUTDOWNCMD "/bin/true"`), para que a lógica real de desligamento permanecesse centralizada no monitor V4. Não habilite simultaneamente políticas concorrentes de desligamento sem rever a arquitetura.

## 6. Mac mini — acesso SSH e receptor seguro

O QNAP envia uma única ação autorizada ao Mac mini, em vez de disponibilizar uma sessão SSH administrativa genérica.

### 6.1. Chave dedicada e comando forçado

O Mac mini utiliza uma entrada em `~/.ssh/authorized_keys` com restrições equivalentes a:

```text
from="<ip-do-qnap>",restrict,command="<caminho-do-receptor>" ssh-ed25519 <chave-publica>
```

A chave privada fica **somente no QNAP**. O endereço e nome de usuário reais são intencionalmente omitidos.

### 6.2. Receptor do Mac mini

Arquivo lógico: `~/bin/ups-receiver.sh`.

- `ups-test`: registra evento de comunicação sem desligar.
- `ups-shutdown`: verifica a presença do arquivo `~/.qnap-ups-shutdown-enabled` e, quando autorizado, executa o desligamento normal do macOS.
- Outros comandos: rejeitados.

A política de permissão do receptor usa um arquivo executável restrito ao proprietário (`chmod 700`).

### 6.3. Regra `sudoers` restrita

O Mac mini foi configurado com autorização **somente para o comando de desligamento**, sem conceder privilégio administrativo geral à chave SSH:

```text
<usuario-mac> ALL=(root) NOPASSWD: /sbin/shutdown -h now
```

Local de instalação: `/private/etc/sudoers.d/<arquivo-dedicado>`, com proprietário `root`, grupo `wheel` e permissão `0440`. A sintaxe deve ser validada com `visudo`.

O receptor invoca:

```sh
sudo -n /sbin/shutdown -h now
```

**MacBook Pro:** não participa do comando remoto de desligamento. Pode continuar usando sua bateria interna e a política de energia do macOS. Um cliente NUT no MacBook pode visualizar dados enquanto o servidor estiver disponível.

## 7. Operação, logs e recuperação

### 7.1. Verificação mínima do sistema

No host QNAP, substitua o nome lógico do nobreak conforme sua configuração:

```sh
# NUT acessível
/sbin/upsc <nome-ups>@127.0.0.1:3493 ups.status

# Supervisor e monitor em execução
ps | grep -E '[q]nap-ups-events-watch.sh|[q]nap-ups-events.sh'

# Somente o container NUT; não divulga outros containers
docker ps --filter 'name=^/nut$' --format '{{.Names}} | {{.Status}}'
```

Os identificadores de processo são transitórios e não devem ser gravados na documentação.

### 7.2. Logs relevantes

- **Eventos:** mudanças `OL`/`OB`, temporizadores, solicitações de desligamento.
- **Ações:** execução SSH e tentativa de desligamento local.
- **Supervisor:** lançamento/reinício do monitor.
- **NUT:** conexão do driver e disponibilidade do serviço.

Em arquivos compartilhados ou relatórios públicos, remova IPs, usuários, chaves, credenciais e dados específicos do ambiente antes de anexá-los.

### 7.3. Recuperação após queda

A recuperação observada foi:

1. Mac mini e QNAP desligaram com falta de energia.
2. QNAP retornou à operação após restabelecimento da alimentação e religamento.
3. Container NUT reiniciou e voltou a fornecer dados.
4. Supervisor e monitor V4 voltaram a executar.

O NUT pode ficar indisponível por alguns minutos **mesmo após o QNAP já responder na rede**, devido à inicialização dos volumes, do Docker e do serviço. Isso não significa, por si só, defeito do driver.

O mecanismo exato que religou o NAS não foi isolado. A opção de recuperação de energia do QTS pode não religar automaticamente um QNAP que tenha sido desligado por software enquanto a saída do nobreak continua energizada.

## 8. Resultado dos testes e limites da solução

**Comprovado em testes físicos:**

- Detecção da falta de energia por NUT.
- Desligamento remoto do Mac mini.
- Desligamento controlado do QNAP.
- Retorno do servidor NUT após a reinicialização.
- Retorno automático do supervisor e do monitor V4.

**Limitações ainda relevantes:**

- Ausência de valor confiável para autonomia restante (`battery.runtime`).
- Tempo de encerramento efetivo do QNAP é maior que o gatilho de 60 segundos e depende das operações em andamento.
- Ação SSH assíncrona não equivale a confirmação de desligamento remoto.
- Perda de comunicação com NUT (`OFFLINE`) não é tratada como falta de energia confirmada.
- A recuperação automática após retorno da energia depende também das políticas e condições de alimentação do NAS.

## 9. Inventário mínimo para backup privado

Preserve em **repositório privado ou backup protegido**, separando configurações públicas de segredos:

- Dockerfile, código-fonte do driver Ragtech e arquivos de build.
- Definição do container NUT e suas configurações (`ups.conf`, `upsd.conf`, `upsd.users`, entrypoint e mapeamento USB).
- Quatro scripts do host QNAP: monitor, controlador, supervisor e inicializador.
- Configuração de autorun QTS e configuração independente do `upsmon`, se utilizada.
- Script receptor do Mac mini e regra restrita de `sudoers`.
- Chaves e credenciais **somente** em armazenamento de segredos ou backup privado criptografado.

Não é necessário copiar nem divulgar serviços Docker de outras aplicações, arquivos de bancos de dados, inventário de rede ou informações de série dos equipamentos para documentar esta solução.

---

**Status final:** arquitetura e operação funcional documentadas, com detalhes identificadores do ambiente removidos. Para reconstrução exata de outro host, usar os arquivos-fonte originais e adaptar caminhos, credenciais, nome do UPS, rede e dispositivos USB à instalação de destino.

# Arquitetura — Nexus Store

Documento de referência para desenvolvedores. Explica como o app está dividido, por que cada
decisão foi tomada e quais alternativas foram descartadas.

---

## 1. Visão geral

```
┌──────────────────────────────────────────────────────────────────────┐
│                         NexusStore (app iOS)                         │
│                                                                      │
│  Features/  ── SwiftUI views (Home, Catalog, Detail, PS4, Admin…)   │
│      │                                                               │
│  App/       ── CatalogStore · TransferCoordinator ·                  │
│                PS4ConnectionService · AppEnvironment · Preferences   │
│      │        (@MainActor, ObservableObject — UI state only)         │
│      ▼                                                               │
│  Core/      ── Foundation puro, testável em Linux                    │
│    Models/      Game, GameDraft, GameCategory, CatalogQuery          │
│    Catalog/     CatalogRepository (JSON atômico), SeedCatalog        │
│    Support/     ByteFormatting, HTTPSURLValidator, SHA256, Artwork   │
│    FTP/         FTPClient (RFC 959) sobre FTPSocket (BSD sockets)    │
│    PS4/         PS4DiscoveryProtocol (DDP) + PS4Discovery (UDP)      │
│    Networking/  URLSessionTransferNetworking, PS4InstallerClient,    │
│                 LocalHTTPFileServer                                  │
│    Transfer/    TransferEngine (fila sequencial), TransferJob,       │
│                 ConsoleProfile, SendingMethod                        │
└──────────────────────────────────────────────────────────────────────┘
        │                                             │
        ▼                                             ▼
   Red local (UDP 987 DDP / TCP FTP)            HTTPS (download .pkg)
        PS4                                        CDN do usuário
```

**Regra de ouro:** `Core/` não importa SwiftUI nem UIKit. Isso permite (a) testar em Linux no CI e
(b) reaproveitar a lógica em uma futura versão macOS/iPad com pouco esforço.

---

## 2. Catálogo

- **Persistência:** um único `catalog.json` em `Application Support/NexusStore/`, escrito com
  `Data.write(options: .atomic)`. O catálogo é pequeno (poucas centenas de KB), então reescrever o
  arquivo inteiro a cada mutação é barato e elimina estados intermediários corrompidos.
- **Esquema:** `CatalogSnapshot { schemaVersion, games, favorites, recentlyViewed, didSeed }`.
  `schemaVersion` permite migrações futuras; o decoder ignora campos desconhecidos.
- **Seed de demonstração:** instalado **uma única vez** (`didSeed`). Apagar todos os jogos não o
  ressuscita. Os jogos de demonstração usam links `https://nexus-store.exemplo/...`, que são
  deliberadamente não roteáveis: a transferência falha rápido, com mensagem clara, em vez de fingir
  uma transferência.
- **Arte de demonstração:** incluída no bundle (gerada para este projeto). Nada é *hotlinked*.

### Por que não Core Data / SwiftData?

O domínio é uma lista de registros independentes, consultada e filtrada em memória. SQLite/Core Data
adicionariam migrações, threading e dependência de framework de persistência sem ganho. O JSON
atômico é verificável por testes e inspecionável pelo usuário.

---

## 3. Descoberta do PS4 (protocolo real)

A descoberta usa o **Device Discovery Protocol (DDP)**, o mesmo protocolo que o app oficial da
PlayStation usa em rede local:

```
iPhone                                   PS4
  │  UDP broadcast 255.255.255.255:987     │
  │───────────────────────────────────────>│
  │  "SRCH * HTTP/1.1\n                    │
  │   device-discovery-protocol-version:   │
  │   00020020\n"                          │
  │                                        │
  │<───────────────────────────────────────│
  │  HTTP/1.1 200 Ok                       │
  │  host-id: PS4-PRO-04B2                 │
  │  host-type: PS4                        │
  │  host-name: PS4 PRO - SALA             │
  │  host-request-port: 997                │
```

- Respostas `200 Ok` = console ligado; `620 Server Standby` = em repouso.
- O app repete o `SRCH` a cada 800 ms até o timeout e também envia para o broadcast `/24` da
  interface Wi-Fi (algumas redes descartam `255.255.255.255`).
- **Limite do protocolo:** DDP descobre, não abre arquivos. **Encontrar o console não significa que
  exista um servidor FTP nele.** O app nunca afirma o contrário: a tela mostra "Servidor FTP ativo"
  apenas após um `USER/PASS` real ter sucesso.
- DDP não informa firmware nem espaço livre; a interface mostra "não informado pelo console" em vez
  de inventar valores.

Referências usadas para validar o formato dos pacotes: implementações abertas do DDP
(`ps4-waker`/`ps4lib`), amplamente documentadas pela comunidade.

---

## 4. FTP (RFC 959) — envio de arquivos

`FTPClient` implementa o subconjunto necessário e nada além:

| Comando | Uso |
|---|---|
| `USER` / `PASS` | login (o `PASS` só é enviado quando o servidor responde 331) |
| `SYST`, `TYPE I` | identificação e modo binário |
| `PWD`, `CWD`, `MKD` | navegação e criação do diretório remoto |
| `PASV` / `EPSV` | modo passivo (único viável atrás de NAT) |
| `STOR` | upload em blocos de 64 KiB |
| `SIZE` | verificação de tamanho remoto (opcional no protocolo) |
| `LIST` / `MLSD` | listagem |
| `QUIT` | encerramento |

Pontos de projeto:

1. **Somente modo passivo.** Modo ativo exige conexão de volta do servidor para o iPhone, que falha
   atrás de NAT e no iOS.
2. **Um job por vez.** Wi-Fi é compartilhado e servidores FTP de console costumam aceitar uma única
   conexão; paralelizar só degradaria as duas transferências.
3. **Sem FTPS silencioso.** Se o servidor exigir TLS (`332`), o app lança `FTPError.tlsRequired` e
   mostra a limitação em vez de fingir sucesso.
4. **Timeout e cancelamento** são cooperativos: cada bloco verifica `isCancelled`; ao cancelar, o app
   fecha o socket de dados e envia `ABOR`.
5. **Progresso real:** `progress(bytesSent, totalBytes)` é chamado a cada bloco. Não existe progresso
   sintético no app.

O teste de integração do CI sobe um **pyftpdlib real** e compara byte a byte o arquivo que o servidor
gravou com o pacote enviado.

---

## 5. Pipeline de transferência

```
ENVIAR PARA PS4
      │
      ▼
┌──────────────┐   valida HTTPS + .pkg, espaço livre no iPhone
│ Preparando   │──erro──> estado ERROR (mensagem real, sem retry falso)
└──────┬───────┘
       ▼
┌──────────────┐   URLSessionDownloadTask (streaming em disco)
│ Baixando     │   Range: bytes=N-  → retoma após pausa/quedas
└──────┬───────┘   pausa cancelável; retomada por Range
       ▼
┌──────────────┐   TCP connect + USER/PASS (FTP passivo)
│ Conectando   │──erro──> ERROR com a resposta do servidor
└──────┬───────┘
       ▼
┌──────────────┐   STOR em blocos de 64 KiB, medição de velocidade (~2 s)
│ Transferindo │   SIZE remoto (quando disponível) valida o arquivo
└──────┬───────┘
       ▼
   Concluído  →  apaga o .pkg temporário (configurável)
```

Estados expostos na UI: **preparando, baixando, conectando, transferindo, pausada, concluída,
cancelada, erro** — todos vêm de eventos reais do motor; a porcentagem, a velocidade e o tempo
restante são calculados a partir de bytes contados.

`TransferEngine` usa um `NSLock` para o estado compartilhado e uma fila de trabalho serial dedicada,
o que garante ordem estrita sem bloquear a main thread. (A primeira versão usava `queue.sync` de dentro
da própria fila durante callbacks de progresso, o que causava deadlock — corrigido e coberto por
teste de cancelamento em fila.)

### Por que não `NWConnection` / `Network.framework` para FTP?

`NWConnection` não fornece um stream bidirecional com semântica de socket para implementar FTP
passivo com portas dinâmicas; BSD sockets dão controle direto de timeout, `SO_BROADCAST` e `recv`
bloqueante, além de compilar em Linux para os testes. `URLSession` continua sendo usado para HTTPS,
onde oferece cache, TLS e retomada.

---

## 6. Arquivo, memória e espaço em disco

| Risco | Mitigação implementada |
|---|---|
| Pacote de dezenas de GB na RAM | download em disco (`URLSessionDownloadTask`), cópia final em blocos de 1 MiB |
| iPhone sem espaço | checagem de `systemFreeSize` antes de baixar (folga de 256 MB) |
| Download interrompido | retomada por `Range`; se o servidor ignorar o range, o arquivo parcial é descartado e recomeça |
| Falha no meio do upload | arquivo temporário removido; estado ERROR com a causa |
| Cancelamento | `ABOR` + remoção do parcial (`cleanTemporaryFilesOnCancel`) |
| Arquivo corrompido no console | `SIZE` remoto comparado ao total enviado (quando o servidor suporta) |
| Comparação byte a byte | valida no CI com servidor real; no dispositivo dependemos de `SIZE`, que é o disponível em FTP |

---

## 7. Segurança

- **Painel admin**: senha com **salt aleatório + SHA-256** (`AdminCredential`), guardada em
  `Application Support`. A senha em si nunca é armazenada. SHA-256 com salt é adequado para um gate
  local de 4+ dígitos; não é usado para proteger dados sensíveis na rede.
- **ATS**: todas as URLs remotas são validadas como `https`. A única exceção é
  `NSAllowsLocalNetworking`, restrita a endereços de rede local, necessária para os serviços do
  console.
- **Servidor HTTP local**: token aleatório de 24 caracteres no caminho, serve **apenas** o arquivo
  temporário da transferência atual, escuta somente enquanto a tela está aberta.
- **Sem telemetria**: nenhuma requisição sai para servidores nossos. Não há backend.

---

## 8. Alternativas avaliadas

| Alternativa | Por que não |
|---|---|
| React Native / Flutter | O que diferencia o app é rede de baixo nível (UDP broadcast, FTP) e integração iOS; nativo evita pontes frágeis. |
| Backend Supabase/Firebase | O briefing pede funcionamento sem serviços pagos; catálogo local resolve. |
| Core Data/SwiftData | Complexidade desproporcional para uma lista de jogos; JSON atômico é testável. |
| `NetFS`/`libcurl` | Sem garantia de presença no iOS, licença e tamanho; `libcurl` não está disponível para apps. |
| FTPS obrigatório | Servidores FTP de console normalmente são FTP puro; o app detecta e informa. |

---

## 9. Extensões previstas

- `URLSession` background (`background(withIdentifier:)`) para downloads longos com o app suspenso.
- TLS (FTPS explícito) quando os servidores de console suportarem.
- Upload resumível via `REST`/`APPE` quando o servidor anunciar suporte.
- Sincronização opcional de catálogo entre dispositivos via arquivo exportável/importável (sem backend).

# NEXUS STORE

**Loja de jogos para PS4, nativa para iPhone — Swift + SwiftUI, catálogo local, descoberta real de console na rede local, envio real de arquivos `.pkg` por FTP e central de transferência com métricas verdadeiras.**

> As telas seguem o layout de referência (fundo preto profundo, vermelho de destaque, cards
> grafite, tab bar fixa). Não há capturas de tela do app em execução neste repositório porque o build
> do iOS exige Xcode/macOS — ver [Limitações conhecidas](#limitações-conhecidas). O ícone do app e as
> artes de demonstração estão em `NexusStore/Resources/Assets.xcassets/`.

---

## O que este repositório entrega

| Área | Estado |
|---|---|
| Catálogo local persistente (JSON atômico em `Application Support`) | ✅ Implementado |
| Pesquisa com normalização de acentos + filtros + ordenação | ✅ Implementado |
| Categorias, favoritos, vistos recentemente, destaques | ✅ Implementado |
| Página individual do jogo com metadados e ações | ✅ Implementado |
| Painel administrativo protegido por senha (SHA-256 + salt) | ✅ Implementado |
| Cadastro/edição/exclusão de jogos com validação campo a campo | ✅ Implementado |
| Descoberta automática do PS4 na rede local (protocolo DDP real, UDP 987) | ✅ Implementado |
| Conexão FTP real (login testado de verdade, sem simulação) | ✅ Implementado |
| Configuração manual do console (IP/porta/usuário/caminho) | ✅ Implementado |
| Download HTTPS do `.pkg` em streaming, com retomada | ✅ Implementado |
| Envio por FTP passivo com progresso real de bytes | ✅ Implementado |
| Central de transferência (porcentagem, velocidade, tempo restante, estados) | ✅ Implementado |
| Instalador HTTP local do PS4 (porta 12800) e servidor HTTP no iPhone | ✅ Implementado (métodos alternativos) |
| Build do app iOS | ⚠️ Código completo; compilação final precisa de Xcode (ver limitações) |
| Testes do núcleo em Swift | ✅ 79 testes automatizados + integração FTP real |

> **Transparência:** este ambiente de desenvolvimento é Linux. O núcleo (catálogo, FTP, DDP,
> transferências) é **compilado e testado** com Swift 6.4 em CI; as telas SwiftUI são verificadas
> por guardas estruturais e revisão, mas **a compilação final do app exige Xcode/macOS**, que não está
> disponível aqui. Nada foi simulado para "parecer pronto" — veja [Docs/LIMITACOES.md](Docs/LIMITACOES.md).

---

## Índice

- [Arquitetura](#arquitetura)
- [Como compilar e instalar](#como-compilar-e-instalar)
- [Configuração do PS4](#configuração-do-ps4)
- [Testes](#testes)
- [Estrutura de pastas](#estrutura-de-pastas)
- [Funcionalidades concluídas e pendências](#funcionalidades-concluídas-e-pendências)
- [Limitações conhecidas](#limitações-conhecidas)
- [Documentação detalhada](#documentação-detalhada)

---

## Arquitetura

O projeto é dividido em **dois consumidores do mesmo código**:

```
NexusStore/
├── Core/        ← Swift puro + Foundation (sem SwiftUI/UIKit)
├── App/         ← camada de estado observável (stores/coordenadores)
├── Features/    ← telas SwiftUI e design system
└── Resources/   ← seed do catálogo, cores, ícone e artes de demonstração
```

Por que isso importa:

1. **Testabilidade real** — `Core/` também é compilado como Swift Package (`Package.swift`), o que
   permite rodar `swift test` em Linux e macOS. É o mesmo código que vai para o app.
2. **Zero dependências externas** — o app não usa SPM remoto, CocoaPods ou Carthage. Abre no Xcode e
   compila sem resolver pacotes, sem Supabase/Firebase e sem custo recorrente.
3. **Núcleo de rede honesto** — FTP, DDP e streaming HTTP são implementados diretamente sobre BSD
   sockets e `URLSession`, com erros explícitos para o usuário.

Detalhes completos (diagramas de camadas, decisões e protocolos) em
[`Docs/ARQUITETURA.md`](Docs/ARQUITETURA.md).

### Stack justificada

| Escolha | Motivo |
|---|---|
| **Swift 5.9+ / SwiftUI (iOS 16+)** | Nativo, sem runtime extra; `NavigationStack`, `@MainActor`, `ObservableObject` e `async/await`. |
| **Foundation puro no Core** | Compila em Linux (CI) e iOS sem `#if` na lógica de negócio. |
| **BSD sockets (`FTPSocket`)** | FTP não existe no `URLSession`. Sockets permitem FTP passivo real, timeouts e testes com socket roteirizado. |
| **`URLSessionDownloadTask`** | Download em disco (streaming), retomada por `Range`, progresso por delegate, memória constante. |
| **JSON atômico no dispositivo** | Catálogo pequeno (centenas de KB); escrita atômica evita corrupção. Sem backend. |
| **DDP (UDP 987)** | É o protocolo real que o app oficial da PlayStation usa para achar o console na rede local. |

---

## Como compilar e instalar

Requisitos: **macOS com Xcode 15+**, um iPhone com **iOS 16+** e (para instalar no aparelho) uma conta
Apple (gratuita ou paga).

```bash
git clone https://github.com/Miguelwelli/Nexusstore.git
cd Nexusstore
open NexusStore.xcodeproj
```

1. Selecione o target **NexusStore** → aba **Signing & Capabilities**.
2. Em **Team**, escolha a sua conta Apple. Se necessário, troque o *Bundle Identifier*
   (`com.nexusstore.app` → `com.seunome.nexusstore`).
3. Conecte o iPhone (ou escolha um simulador) e pressione **⌘R**.
4. Para instalar no aparelho físico: confie no certificado em **Ajustes → Geral → VPN e Gerenciamento
   de Dispositivos**.
5. Na primeira abertura do app, permita **Rede Local** quando o iOS perguntar (necessário para
   descobrir o PS4).

Validação por linha de comando (também em macOS):

```bash
xcodebuild -project NexusStore.xcodeproj -scheme NexusStore \
           -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Guia completo, incluindo TestFlight e geração de IPA, em [`Docs/BUILD.md`](Docs/BUILD.md).

Regenerar o projeto após adicionar arquivos:

```bash
python3 Tools/generate_xcodeproj.py   # o CI falha se o projeto estiver desatualizado
```

---

## Configuração do PS4

A Nexus Store fala com o console **na sua rede local**, sem nuvem. Nada é enviado para a internet.

### 1. Descoberta (funciona sem configuração)

- O iPhone e o PS4 precisam estar **na mesma rede Wi-Fi**.
- O app envia um pacote `SRCH * HTTP/1.1` em broadcast UDP para a porta **987** (Device Discovery
  Protocol — o mesmo usado pelo app oficial da PlayStation) e lista os consoles que responderem.
- Se o console estiver **em repouso**, ele responde com `620 Server Standby` e o app mostra "Em espera".
- Em redes com *client isolation* (Wi-Fi de hotel, muitas redes de convidados) o broadcast é bloqueado.
  Nesse caso use **Configurar manualmente** com o IP do console (Ajustes → Rede → Status da conexão).

### 2. Envio por FTP (servidor do console)

O PS4 **não expõe FTP de fábrica**. É preciso um servidor FTP compatível em execução no console
(instalado pelo próprio usuário, fora do escopo deste app). O Nexus Store então:

1. Baixa o `.pkg` por HTTPS para o iPhone (streaming, com retomada).
2. Abre uma conexão FTP real (passivo) com o console — padrão **porta 2121**, usuário `anonymous`.
3. Envia o arquivo por `STOR` em blocos de 64 KiB, medindo bytes e velocidade de verdade.
4. Quando o servidor implementa `SIZE`, o app confere o tamanho remoto antes de declarar sucesso.

> **Importante:** enviar o `.pkg` por FTP **não instala o jogo**. A instalação depende do ambiente
> configurado no console. O app nunca afirma que instalou algo.

### 3. Métodos alternativos (também implementados)

- **Instalador do console (porta 12800)** — `POST multipart/form-data` para `/upload`, usado por
  toolkits de instalação locais. Requer que o console aceite esse endpoint no ambiente do usuário.
- **iPhone como servidor HTTP** — publica o arquivo temporário em `http://<ip-do-iphone>:8080/<token>/nome.pkg`
  para ser aberto no navegador do PS4. O token evita acesso a outros arquivos.

Passo a passo com capturas em [`Docs/PS4-SETUP.md`](Docs/PS4-SETUP.md).

---

## Testes

```bash
swift test                     # 79 testes do núcleo (Linux/macOS)
python3 Tools/verify_xcodeproj.py
python3 Tools/check_swift_style.py
```

O CI (GitHub Actions, `.github/workflows/ci.yml`) executa, a cada push:

1. **Guardas**: projeto Xcode sincronizado com os fontes, parênteses/chaves balanceados, sem
   `TODO`/`fatalError` em telas.
2. **Build + 79 testes** com Swift 6.4 (Linux).
3. **Integração real de FTP**: sobe um **servidor FTP de verdade** (pyftpdlib) e envia um pacote de
   2 MiB com o mesmo `FTPClient` usado no app, validando tamanho, progresso incremental, `SIZE` e `LIST`.

Cobertura atual (resumo):

| Suíte | O que valida |
|---|---|
| `CatalogTests` | CRUD, persistência entre aberturas, nomes duplicados, favoritos, recentes, JSON corrompido |
| `GameDraftValidationTests` | Validação campo a campo, links HTTPS + `.pkg`, normalização |
| `FormattingAndValidationTests` | tamanhos (`48,5 GB`), velocidades, porcentagens, URLs, SHA-256 (vetores oficiais) |
| `FTPTests` | diálogo completo com socket roteirizado: login, PASV/EPSV, STOR, cancelamento, multi-linha |
| `FTPIntegrationTests` | **servidor real**: upload de 2 MiB, senha errada, porta fechada |
| `PS4DiscoveryProtocolTests` | pacote `SRCH`, resposta `200 Ok`/`620 Standby`, pacotes inválidos |
| `TransferEngineTests` | fluxo completo, falhas reais, fila sequencial, cancelamento, limpeza de temporários |
| `TransferConfigurationTests` | preferências aplicadas ao motor, arquivo truncado detectado, limpeza no cancelamento |
| `SeedCatalogTests` | catálogo embutido válido e links de demonstração não roteáveis |

Relatório detalhado (incluindo o que **não** pôde ser testado aqui) em [`Docs/TESTES.md`](Docs/TESTES.md).

---

## Estrutura de pastas

```
.
├── NexusStore.xcodeproj/          # projeto gerado (sem dependências externas)
├── NexusStore/
│   ├── App/                       # entry point, stores observáveis, coordenadores
│   ├── Core/                      # Swift puro: modelos, catálogo, FTP, DDP, transferência
│   │   ├── Models/  Catalog/  FTP/  PS4/  Networking/  Transfer/  Support/
│   ├── Features/                  # telas SwiftUI (Home, Catalog, Detail, PS4, Admin, Design…)
│   ├── Resources/                 # seed.json, Assets.xcassets (ícone, cores, artes demo)
│   └── Info.plist
├── Tests/NexusStoreCoreTests/     # XCTest do núcleo
├── Tools/                         # gerador do .xcodeproj, guardas, servidor FTP de teste, CI
├── Docs/                          # arquitetura, PS4, build, testes, limitações
└── Package.swift                  # empacota Core + testes para `swift test`
```

---

## Funcionalidades concluídas e pendências

### Concluído

- Cinco abas funcionais: **Início, Jogos, Categorias, Pesquisa, PS4**.
- Identidade visual preta/vermelha, cards grafite, tipografia branca, tab bar fixa com indicador
  vermelho, animações e ícones SF Symbols.
- Catálogo persistente com seed de demonstração claramente marcado (`DEMO`) e links não roteáveis.
- Pesquisa sem acentos, filtros combináveis, ordenação, favoritos, recentes, destaques.
- Página do jogo com estatísticas, metadados, seção "Sobre", capturas e CTA **ENVIAR PARA PS4**.
- Painel administrativo com senha (hash + salt), validação e CRUD completo.
- Descoberta DDP real + conexão FTP real + configuração manual + consoles recentes.
- Central de transferência com porcentagem, barra, velocidade, tempo restante, bytes enviados,
  estados (preparando, baixando, conectando, transferindo, pausado, concluído, erro) e cancelamento.
- Limpeza de temporários, verificação de espaço livre antes do download, retomada por `Range`.
- 79 testes automatizados + integração com servidor FTP real.

### Pendências / necessitam de ambiente macOS ou do console

| Item | Motivo |
|---|---|
| Compilação final e instalação em iPhone | Exige Xcode/macOS (indisponível neste ambiente). |
| Teste em um PS4 físico | Sem acesso a um console real aqui; os protocolos foram validados com servidor FTP real e parser DDP testado. |
| Servidor FTP de console específico | Depende do homebrew escolhido pelo usuário; o app usa FTP padrão passivo, o mais compatível. |
| FTPS (TLS) | Não implementado; o app **avisa** e não finge sucesso (`FTPError.tlsRequired`). |
| Transferência em segundo plano (suspensão do iOS) | Requer `URLSession` background + entitlements; documentado como evolução. |
| Notificações push | Não necessário para o escopo; o badge interno funciona. |

---

## Limitações conhecidas

1. **Plano de fundo**: se o app for suspenso pelo iOS durante o envio FTP, a conexão cai. A tela avisa
   para manter o app aberto (o download HTTPS em si usa `URLSession`, mas o FTP é socket direto).
2. **Instalação de PKG**: o app move arquivos; ele não instala jogos e nunca afirma que instalou.
3. **Conteúdo**: o catálogo de demonstração usa links em `nexus-store.exemplo` (não roteáveis) e artes
   geradas para este projeto. Jogos reais só entram via painel administrativo, com links do usuário.
4. **Rede local**: discovery depende de broadcast; redes com isolamento de clientes exigem IP manual.
5. **Idioma**: interface em português (pt-BR), conforme o briefing.

---

## Documentação detalhada

| Documento | Conteúdo |
|---|---|
| [`Docs/ARQUITETURA.md`](Docs/ARQUITETURA.md) | Camadas, fluxos, protocolos (FTP/DDP), decisões e alternativas |
| [`Docs/PS4-SETUP.md`](Docs/PS4-SETUP.md) | Requisitos no console, portas, descoberta, solução de problemas |
| [`Docs/BUILD.md`](Docs/BUILD.md) | Xcode, assinatura, simulador, TestFlight, IPA |
| [`Docs/TESTES.md`](Docs/TESTES.md) | Suítes, execução local, CI, evidências e lacunas |
| [`Docs/LIMITACOES.md`](Docs/LIMITACOES.md) | Limitações técnicas e o que exige macOS/console |
| [`Docs/ETICA-E-DIREITOS.md`](Docs/ETICA-E-DIREITOS.md) | Responsabilidade sobre conteúdo e uso de pacotes |

---

## Aviso

A Nexus Store é uma **ferramenta pessoal de gerenciamento de catálogo e transferência de arquivos**.
Ela não contorna proteções, não distribui jogos e não inclui conteúdo de terceiros. O usuário é
responsável pelos arquivos que cadastra e pelos direitos de distribuí-los. Enviar um `.pkg` por FTP
não instala nem desbloqueia nada no console.

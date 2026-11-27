# Configurando o PS4 para usar com a Nexus Store

Este guia é deliberadamente honesto: **não existe FTP "de fábrica" no PlayStation 4** e a Nexus Store
não contorna proteções do console. Para enviar arquivos, o console precisa de um **servidor FTP
compatível em execução**, instalado pelo próprio usuário. Sem isso, o app continua funcionando como
catálogo e central de download — apenas o envio ao console não estará disponível.

---

## 1. Antes de começar

| Requisito | Detalhe |
|---|---|
| iPhone | iOS 16 ou superior, conectado à **mesma rede Wi-Fi** do PS4 |
| PS4 | Ligado (ou em repouso para descoberta), com IP na rede local |
| Rede | Sem *client isolation* (redes de hotel/convidados bloqueiam broadcast) |
| Console | Servidor FTP ativo no console para envio de arquivos |
| Licença | Você é responsável pelos arquivos enviados e pelos direitos sobre eles |

Para ver o IP do console: **Ajustes → Rede → Ver status da conexão**. Anote o endereço `192.168.x.x`.

---

## 2. Descoberta automática (não requer configuração)

1. Abra o app e toque em **PS4** na barra inferior.
2. O app envia pacotes de descoberta (UDP 987) e mostra os consoles que responderem.
3. Toque em **CONECTAR AO CONSOLE**.

Estados possíveis:

| Estado | Significado |
|---|---|
| `DISPONÍVEL` | O console respondeu `200 Ok` — está ligado. |
| `EM ESPERA` | Respondeu `620 Server Standby` — ligado em modo de repouso. |
| `NENHUM CONSOLE ENCONTRADO` | Nada respondeu: Wi-Fi diferente, *client isolation*, ou console desligado. |
| `CONECTADO` | O **login FTP real** foi concluído com sucesso. |

> O iOS pede permissão de **Rede Local** na primeira busca. Se negada, o app não consegue descobrir
> nem conectar: reative em **Ajustes → Nexus Store → Rede Local**.

---

## 3. Servidor FTP no console

O app usa FTP **padrão, modo passivo**, porta **2121** por padrão — a mesma configuração usada pela
maioria dos servidores FTP de console. Recomendações ao escolher/configurar o servidor:

- Ativar modo **passivo** (PASV). O modo ativo não funciona atrás de NAT.
- Permitir escrita no diretório onde os pacotes serão enviados.
- Usuário `anonymous` (o app tenta sem senha por padrão) ou cadastre um usuário e informe em
  **Configurar manualmente**.
- Evitar FTPS/TLS: o app ainda **não** suporta e mostra um erro explícito.

Depois de ativo no console:

1. No app, toque em **PS4 → CONECTAR AO CONSOLE** (ou **Configurar manualmente** e informe IP + porta).
2. O app executa uma conexão FTP de verdade: `220` → `USER` → `PASS` → `SYST`.
3. Só então o console aparece como **CONECTADO**.

### Configuração manual

Use quando a descoberta não funcionar:

| Campo | Exemplo |
|---|---|
| Nome do console | `PS4 PRO - SALA` |
| Endereço IP | `192.168.1.104` |
| Porta FTP | `2121` |
| Usuário FTP | `anonymous` |
| Caminho remoto | `/` ou `/packages` |

O app valida IP, porta e caminho antes de salvar e permite **Salvar e testar FTP** (teste real).

---

## 4. Enviando um jogo

1. Abra o jogo no catálogo.
2. Toque em **ENVIAR PARA PS4**.
3. O app valida o link `.pkg` (precisa ser **HTTPS**), o espaço livre no iPhone e o console de destino.
4. Acompanhe na **Central de Transferência**: baixando → conectando → transferindo → concluído.
5. Ao final, se o servidor suportar `SIZE`, o tamanho remoto é conferido.

> **O arquivo é movido, não instalado.** Enviar um `.pkg` por FTP não instala, não desbloqueia e não
> altera o jogo no console. A instalação depende inteiramente do ambiente configurado no console pelo
> usuário — a Nexus Store não faz isso e não afirma que fez.

### Métodos alternativos de envio

A tela **Configurar console → Método de envio** permite escolher:

| Método | Quando usar |
|---|---|
| **FTP (servidor do console)** | Há um servidor FTP ativo no console (mais comum). |
| **Instalador do console (porta 12800)** | O ambiente do console expõe o instalador HTTP local. O app envia `multipart/form-data` para `/upload`. |
| **iPhone como servidor HTTP** | O console tem navegador, mas não FTP. O app publica o arquivo em `http://<ip-do-iphone>:8080/<token>/<arquivo>.pkg`; abra esse endereço no navegador do PS4. |

---

## 5. Solução de problemas

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| Nenhum console encontrado | Wi-Fi diferente, console desligado, isolamento de clientes | Conferir rede; usar IP manual |
| "Falha ao abrir a busca na rede local" | Permissão de Rede Local negada | Ajustes → Nexus Store → Rede Local |
| "Não foi possível alcançar …:2121" | IP errado, porta diferente ou servidor FTP inativo | Testar porta no console, conferir configuração manual |
| "Login recusado" | Usuário/senha exigidos | Informar usuário correto na configuração manual |
| "O servidor exige FTPS (TLS)" | Servidor configurado com TLS | Reativar FTP puro no servidor do console |
| Transferência para em 100% | Servidor lento para fechar a conexão de dados | Aguardar; se persistir, testar com outro servidor |
| "Resposta inesperada do servidor para SIZE" | Arquivo incompleto no console | Refazer o envio; espaço insuficiente no console é a causa comum |
| App fecha ao enviar | iOS suspendeu o app | Manter o app aberto durante a transferência (limitação documentada) |

---

## 6. Privacidade

- Descoberta e FTP acontecem **somente na rede local**.
- O download do `.pkg` usa o link HTTPS cadastrado pelo usuário (CDN dele).
- O app não possui backend, telemetria ou contas.
- A senha do painel administrativo é guardada como hash com salt no próprio iPhone.

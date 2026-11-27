# Limitações conhecidas — o que foi feito e o que não foi possível fazer aqui

Este documento existe para que nada seja superestimado. Ele separa **limitações do app** (por
projeto) de **limitações deste ambiente de desenvolvimento**.

---

## 1. Limitações do ambiente usado para construir o app

| Fato | Consequência |
|---|---|
| O ambiente é **Linux**, sem Xcode/macOS | O `.xcodeproj` foi gerado por script e **não foi compilado** com `xcodebuild` aqui. |
| Runners macOS no CI ficaram indisponíveis (cancelados na fila, sem runner atribuído) | Não foi possível compilar o app iOS automaticamente. |
| Sem iPhone físico nem PS4 | Não houve teste em hardware real nem com um console. |
| Rede com acesso restrito | Dependências foram evitadas por projeto (zero SPM/CocoaPods), o que também elimina esse risco. |

### O que foi feito para compensar

1. **Núcleo compilado e testado de verdade:** Swift 6.4 no Linux, 116 testes automatizados.
2. **Integração real de FTP:** servidor pyftpdlib sobe no CI; upload de 2 MiB verificado byte a byte.
3. **Todos os 71 arquivos Swift passam pelo parser do compilador** (`swiftc -frontend -parse`),
   incluindo as telas SwiftUI que só compilam no Xcode.
4. **Guardas estruturais:** projeto Xcode sincronizado com os fontes, chaves/parênteses equilibrados,
   arquivos sem `TODO`/`fatalError` nas telas.
5. **Revisão manual** de cada tela contra a identidade visual de referência.

### O que continua sendo necessário

- Abrir o projeto no **Xcode** e rodar `⌘B`/`⌘R`. É esperado que ajustes finos de compilação de UI
  (por exemplo, uma inferência de tipo em uma expressão muito grande) possam surgir nesse momento;
  o código foi escrito para minimizar isso, mas **não é possível afirmar "compila" sem compilar**.
- Testar em um iPhone real: permissão de Rede Local, descoberta DDP e FTP.
- Testar com o servidor FTP do console escolhido pelo usuário.

---

## 2. Limitações do aplicativo (por projeto)

| Limitação | Detalhe | Mitigação |
|---|---|---|
| FTP não instala PKG | É transferência de arquivo; instalação depende do console | A UI avisa explicitamente, em três telas |
| Sem FTPS/TLS | Servidores com TLS não são suportados | Erro claro (`FTPError.tlsRequired`) em vez de falha silenciosa |
| Sem modo ativo | NAT/iOS impedem conexão de retorno | Somente modo passivo, documentado |
| App suspenso interrompe FTP | Sockets diretos não sobrevivem à suspensão do iOS | Alerta automático ao sair do app durante o envio + aviso na Central; download HTTPS é retomável |
| Sem retomada de upload | FTP não padroniza `REST` para `STOR` de forma confiável | Cancelamento limpa o parcial; novo envio recomeça do zero |
| Descoberta depende de broadcast | Redes com isolamento bloqueiam | Campo de IP manual + consoles recentes |
| Firmware/espaço do console | DDP não expõe esses dados | A UI mostra "não informado", nunca um valor inventado |
| Catálogo é local ao dispositivo | Sem sincronização entre aparelhos | Exportação futura planejada; sem backend por decisão de escopo |
| Sem notificações push | Não há servidor | Badge interno e progresso na tab bar |

---

## 3. Dados de demonstração

- Os 7 jogos iniciais existem para mostrar o catálogo funcionando no primeiro uso.
- Todos usam links `https://nexus-store.exemplo/...` (**domínio não roteável**): qualquer tentativa de
  envio falha com mensagem clara e **não** gera transferência falsa.
- As artes foram geradas para este projeto; nenhum material de terceiros foi incluído.
- Os cards de demonstração exibem o selo **DEMO** e podem ser editados ou apagados no painel admin.
- O seeded só é aplicado uma vez (`didSeed`): apagar tudo não recria os exemplos.

---

## 4. O que o app não faz (por princípio)

- Não contorna DRM, bloqueios ou proteções do console.
- Não distribui jogos nem inclui links de conteúdo protegido.
- Não simula transferências, porcentagens ou conexões.
- Não envia dados do usuário para servidores externos.
- Não afirma ter instalado um jogo após um upload.

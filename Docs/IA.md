# Assistente IA — Auto-Catálogo

Funcionalidade do painel administrativo que busca jogos de PS4, extrai metadados reais e prepara os
cadastros para aprovação.

```
Painel Administrativo → Assistente IA — Auto-Catálogo
```

---

## 1. Decisão de arquitetura: por que a busca não usa Gemini

O pedido original era integrar a **Google Gemini API** e ter a IA pesquisando jogos. Há um conflito
técnico real que precisa ser dito com clareza:

| Necessidade | Gemini (LLM) | RAWG (banco de dados) |
|---|---|---|
| Título, capa, gêneros, publisher | **Não garante** — responde da memória do modelo | Devolve campo a campo, de uma base mantida |
| Tamanho do `.pkg`, versão exata | Inventa com frequência (números plausíveis e errados) | Não informa (e o app deixa vazio em vez de chutar) |
| Fonte verificável por registro | Não | Sim: URL `rawg.io/games/<slug>` |
| Funciona sem backend | Sim | Sim |
| Custo | Pago por token | Gratuito (com limite de requisições) |

Como o requisito explícito era **"não invente informações ausentes"** e **"não classifique um link como
verificado só porque parece correto"**, um LLM como fonte de metadados produziria exatamente o que foi
proibido. Por isso:

- **A busca de metadados usa a API oficial da RAWG** (plataforma PS4 = id 18), que é um banco de dados
  real, com capas oficiais e página de origem para conferência.
- **Nenhum tamanho, versão ou link `.pkg` é preenchido pela IA.** Esses campos chegam vazios e o
  candidato fica marcado como incompleto até o administrador informar (ou até um link autorizado
  passar na verificação HTTP).
- **A camada Gemini é opcional e exige backend.** Chamar `generativelanguage.googleapis.com`
  diretamente do app exigiria embutir a chave no binário — ela seria extraível do IPA em minutos, o
  que o próprio pedido proíbe. O caminho correto seria uma função de nuvem (Cloud Functions / Worker)
  guardando a chave, com o app enviando apenas texto. Isso está descrito no item 6 como próximo passo,
  não implementado.

O rótulo "Modelo de IA" na tela lista o provedor efetivamente usado (RAWG) — não um modelo Gemini
fictício. Se uma camada Gemini for adicionada, ela aparece nesse seletor.

## 2. Fluxo implementado

1. **Configuração** — chave RAWG guardada no **Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`),
   botão *Testar Conexão* que faz uma requisição real (`page_size=1`) e mostra a latência em ms.
2. **Parâmetros** — categorias (chips), quantidade de 1 a 20, opção de extrair capa/banner.
3. **Busca** — `GET https://api.rawg.io/api/games?platforms=18&genres=…&ordering=-rating`.
   401 → "chave recusada"; 429 → limite com `Retry-After`; falha de rede → mensagem real.
4. **Deduplicação** — título normalizado (sem acento, sem pontuação) contra o catálogo **e** dentro do
   próprio resultado. O contador "N duplicados ignorados" aparece após a busca.
5. **Revisão** — card por jogo com capa, nome, tamanho, versão, plataforma, gênero, descrição, banner,
   fonte clicável e situação do link PKG. *Editar/Rejeitar* e *Aprovar e Cadastrar* por card,
   *Aprovar todos* no rodapé.
6. **Cadastro** — a aprovação grava no **mesmo** `catalog.json` do catálogo existente, via
   `CatalogIngestion` (deduplicação e validação compartilhadas com o formulário manual).
7. **Histórico** — últimas 50 buscas em `auto-catalog.json`, com repetir pesquisa e excluir.

## 3. Regras de link PKG

`PKGLinkVerifier` faz uma checagem HTTP real e nada além disso:

- exige `https://` e caminho terminando em `.pkg` (senão nem dispara requisição);
- `HEAD`, com fallback de `GET` + `Range: bytes=0-0` quando o servidor não implementa `HEAD`;
- rejeita `text/html`, `application/json` e afins (página de erro/landing);
- rejeita arquivos abaixo de 256 KB (impossível para um jogo de PS4);
- 401/403 → "exige autenticação"; 404/410 → "não existe mais";
- resultado guardado como `verified` / `rejected` / `notChecked`, com o motivo.

**Verificado ≠ autorizado.** O app avisa isso na tela: a checagem prova que o endereço responde com um
binário, não que você tem direito de distribuí-lo. O assistente **nunca inventa** um link: ele só usa
links informados pelo administrador, e um jogo com link não verificado fica bloqueado para aprovação.

## 3.1 Licença da RAWG (obrigatório)

O plano gratuito da RAWG autoriza uso pessoal **desde que**:

- a RAWG seja atribuída como fonte dos dados e imagens;
- exista um **hyperlink ativo** em toda tela onde os dados aparecem.

O app cumpre isso em dois lugares: a tela de configuração e a tela de revisão mostram
"Dados e imagens: RAWG Video Games Database" com link para `https://rawg.io`. O campo `sourceURLString`
de cada candidato aponta para a página do jogo na RAWG.

Restrições adicionais do plano gratuito: até 20.000 requisições/mês, uso não comercial e proibição de
redistribuir os dados como API. Para uso comercial acima dos limites, é necessário contratar o plano
pago da RAWG — nada neste app contorna esse limite.

## 4. Chave de API

- Fica no **Keychain**, nunca em `UserDefaults`, nunca em arquivo do repositório, nunca em log.
- É enviada apenas para `api.rawg.io` (a mesma URL que o app consulta). Não há proxy.
- `Docs/LIMITACOES.md` registra que a chave viaja na query string, como a API da RAWG exige; em rede
  hostil isso é interceptável apenas por TLS quebrado (o app só fala HTTPS).

## 5. Testes

`Tests/NexusStoreCoreTests/AutoCatalogTests.swift` — 24 testes contra um `URLProtocol` falso que
devolve JSON no formato da RAWG:

- conexão com latência, 401, 429 com `Retry-After`, chave vazia (falha antes de qualquer requisição);
- mapeamento de campos reais, `sizeText` vazio (nunca inventado), `platforms=18` na URL;
- deduplicação entre catálogo e resultado + contagem de duplicados;
- link PKG: HTML rejeitado, 404 rejeitado, binário pequeno rejeitado, HTTP plano rejeitado sem requisição;
- aprovação real em `CatalogRepository`, dupla aprovação recusada, *aprovar todos* pulando incompletos;
- histórico persistido, limitado e com rejeição preservada.

## 6. Próximo passo (não implementado)

Camada Gemini para **texto** (descrição em português, tags), com:

1. função de nuvem guardando a chave do Google;
2. o app envia apenas o título do jogo e recebe texto;
3. o texto entra numa proposta de descrição e continua exigindo aprovação humana.

Nada disso foi feito, e o app não finge que foi.

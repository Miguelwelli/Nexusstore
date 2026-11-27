# Testes e validação

## Como rodar

```bash
swift test                                   # 101 testes (Core) — Linux e macOS
python3 Tools/verify_xcodeproj.py            # projeto Xcode em sincronia com os fontes
python3 Tools/check_swift_style.py           # guardas estruturais nos arquivos Swift
./Tools/ci/parse_all.sh $(find NexusStore Tests -name '*.swift')
```

Integração com servidor FTP real (qualquer máquina com Python):

```bash
python3 -m pip install pyftpdlib
python3 Tools/ci/ftp_test_server.py 2121 /tmp/ftproot &
NEXUS_FTP_INTEGRATION=1 NEXUS_FTP_HOST=127.0.0.1 NEXUS_FTP_PORT=2121 \
NEXUS_FTP_USER=ps4 NEXUS_FTP_PASSWORD=ps4 NEXUS_FTP_ROOT=/tmp/ftproot \
swift test --filter FTPIntegrationTests
```

---

## Suítes e o que cada uma prova

### `ByteFormattingTests`
- `48,5 GB`, `48.5 GB`, `900 MB`, `1 TB` e bytes crus são convertidos corretamente (unidades binárias).
- Rejeita entradas inválidas (`""`, `"grande"`, `"12 XB"`, negativos).
- Velocidade (`92.4 MB/s`) e tempo restante (`~5 min`, `~1h`).
- Porcentagem é limitada a `0...100`.

### `URLValidatorTests` / `ArtworkReferenceTests`
- Só aceita HTTPS; HTTP e FTP são rejeitados com mensagem específica.
- Link de download precisa terminar em `.pkg`.
- Artes aceitam HTTPS ou nome de asset do bundle; entradas inválidas não passam.
- Nome do pacote no console é derivado da URL (slug como fallback).

### `GameDraftValidationTests`
- Draft válido passa; draft vazio reporta **todos** os campos de uma vez.
- HTTP, `.zip` e tamanho inválido são barrados.
- Edição preserva `id` e `createdAt` e atualiza `updatedAt`.
- Campos são aparados e atributos separados por vírgula.

### `CatalogRepositoryTests`
- Persistência real em disco: reabrir a `CatalogRepository` devolve os mesmos dados.
- Nomes duplicados (case-insensitive) são recusados.
- Update/delete, favoritos e "vistos recentemente" (ordem e limite).
- Apagar todos os jogos **não** reinstala o seed.
- JSON corrompido não derruba o app (catálogo vazio) e o arquivo é gravado atomicamente.

### `CatalogQueryTests`
- Busca sem acento e sem caixa (`RAGNAROK` → `God of War Ragnarök`).
- Filtros combináveis (união de categorias) e quatro ordenações.
- Destaque, recentes e contagem por categoria.

### `FTPClientTests` (socket roteirizado)
- Saudação, login com e sem senha (só envia `PASS` após `331`), login recusado.
- Respostas multi-linha (`220-...` até `220 `).
- `PASV` (incluindo endereço `0.0.0.0` → usa o host de controle) e fallback para `EPSV`.
- `STOR` envia 150 KiB em 3 blocos de 64 KiB, com progresso cumulativo e fechamento do socket de dados.
- Cancelamento interrompe o upload antes de completar.
- Parser de `LIST` e de códigos de resposta.

### `FTPIntegrationTests` (servidor real, CI)
- Upload de 2 MiB para **pyftpdlib real**, com progresso incremental.
- Comparação **byte a byte** do arquivo gravado no servidor com o pacote local.
- `SIZE` e `LIST` validados quando disponíveis.
- Senha errada recebe `loginFailed`; porta fechada recebe erro de socket.

### `PS4DiscoveryProtocolTests`
- Pacote `SRCH * HTTP/1.1` + `device-discovery-protocol-version` exatamente no formato esperado.
- Resposta `200 Ok` (ligado, `host-request-port` 997) e `620 Server Standby` (repouso).
- Pacotes que não são de console são ignorados; formato com `\n` apenas é tolerado.
- A varredura real não trava e nunca inventa consoles.

### `ConsoleProfileTests`
- Validação de IP/porta/caminho.
- JSON antigo sem `preferredMethod` continua decodificando.
- A matriz de métodos de envio é coerente (FTP e instalador automáticos; HTTP local assistido).

### `TransferEngineTests`
- Link HTTP inválido falha **antes** de qualquer acesso à rede.
- Fluxo completo (download → FTP → conclusão), com `STOR`, limpeza do temporário e eventos de estado.
- Falha de download → estado `failed` com mensagem real.
- Console sem FTP → `failed`, nunca "concluído".
- Dois jobs rodam **em sequência**.
- Cancelar um job na fila produz evento `cancelled`.
- `discardTemporaryFile` remove o artefato.

### `TransferConfigurationTests`
- `deleteLocalFileWhenDone = false` mantém o `.pkg` após sucesso; alteração via
  `updateConfiguration` vale para o próximo job.
- Servidor que anuncia 100 KB e entrega 8 KB → estado `failed` (nunca "concluído").
- Cancelamento remove o parcial quando configurado.

### `AdminCredentialTests`
- SHA-256 validado contra vetores oficiais (`"abc"`, vazio, 1000 × `"a"`).
- Salt diferente gera hash diferente; validação de senha mínima.

### `SeedCatalogTests`
- O JSON do catálogo de demonstração existe, decodifica e todos os campos são coerentes.
- Todos os links de demonstração são **não roteáveis** (`exemplo`) — impossível parecer real.
- Os nomes do seed coincidem com `SeedCatalog.sampleNames` (usado para o selo DEMO).

---

## Evidências do CI

- `Swift core (build + tests)` — build + 101 testes: **sucesso**.
- `FTP integration (real server)` — 3 testes com pyftpdlib: **sucesso**.
- `Tools/ci/parse_all.sh` — 71 arquivos Swift aprovados pelo parser do compilador.
- `Tools/check_workflows.py` — impede YAML inválido nos workflows (ver LIMITACOES).
- `Swift core summary` (notice do CI): `Executed 101 tests, with 3 tests skipped and 0 failures`.

> Logs completos ficam em **Actions → CI**. O acesso aos logs brutos via API é bloqueado neste
> ambiente; os resultados foram lidos pelas *annotations* dos jobs (sucesso/falha por teste).

---

## Lacunas de teste (honestas)

| Não testado aqui | Motivo | Como validar |
|---|---|---|
| Compilação do app iOS | Sem Xcode/macOS | `xcodebuild` em um mac (Docs/BUILD.md) |
| Descoberta DDP com PS4 físico | Sem console | Rodar o app na mesma Wi-Fi do PS4 |
| FTP em servidor de console real | Sem console | Testar com o servidor do usuário |
| Transferência de arquivo > 4 GB | Tempo/espaço no CI | Testar manualmente com um `.pkg` grande |
| Telas SwiftUI compiladas | Sem Xcode | `xcodebuild` em um mac (Docs/BUILD.md) — hoje garantido: parse do compilador + guardas estruturais |
| Suspensão do app durante FTP | Requer dispositivo | Testar em iPhone com bloqueio de tela |

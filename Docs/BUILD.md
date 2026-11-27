# Compilando e instalando a Nexus Store

Requisitos: **macOS 13+**, **Xcode 15+** (Swift 5.9+), **iPhone com iOS 16+**.
Não há dependências externas: o projeto não resolve Swift Packages, CocoaPods ou Carthage.

---

## 0. Existe um .ipa pronto?

Não. E isso é proposital:

- Um `.ipa` só instala no iPhone se estiver **assinado com o seu certificado Apple** e vinculado ao seu
  aparelho/conta. Um `.ipa` "genérico" baixado da internet não funciona no seu iPhone.
- Assinar exige macOS + Xcode + sua conta Apple. Não é possível gerar nem assinar um `.ipa` neste
  ambiente (Linux) nem no CI usado por este repositório (sem runners macOS disponíveis).
- Existe o workflow manual `.github/workflows/ios-ipa.yml`, que produz um `.ipa` **não assinado** para
  quem tiver runners macOS: ele ainda precisa ser assinado (Xcode, Apple Configurator ou uma
  ferramenta como o `codesign`/Sideloadly).

O caminho mais rápido e gratuito: siga o passo 2 abaixo (10 minutos, com seu Apple ID).

## 1. Abrir o projeto

```bash
git clone https://github.com/Miguelwelli/Nexusstore.git
cd Nexusstore
open NexusStore.xcodeproj
```

O projeto é gerado por `Tools/generate_xcodeproj.py`. Se você adicionar/remover arquivos:

```bash
python3 Tools/generate_xcodeproj.py
```

O CI falha se o `.xcodeproj` estiver dessincronizado com os fontes (`Tools/verify_xcodeproj.py`).

---

## 2. Assinatura (obrigatório para rodar no iPhone)

1. Selecione o target **NexusStore** no navegador do Xcode.
2. Aba **Signing & Capabilities**.
3. Marque **Automatically manage signing** e escolha seu **Team** (Apple ID gratuito serve).
4. Se o *Bundle Identifier* `com.nexusstore.app` já estiver em uso na sua conta, troque para algo
   único, por exemplo `br.com.seunome.nexusstore`.
5. Para instalar no aparelho: **⌘R** com o iPhone conectado. No primeiro uso, confie no desenvolvedor
   em **Ajustes → Geral → VPN e Gerenciamento de Dispositivos**.

Conta gratuita tem validade de 7 dias por build; conta paga (Apple Developer Program) permite
TestFlight e builds de 1 ano.

---

## 3. Simulador

```bash
xcodebuild -project NexusStore.xcodeproj -scheme NexusStore \
           -destination 'generic/platform=iOS Simulator' \
           build CODE_SIGNING_ALLOWED=NO
```

Atenção: o **simulador não possui rede local real**. Descoberta DDP e FTP só têm significado em um
iPhone físico na mesma Wi-Fi do console; no simulador o app mostra corretamente "nenhum console
encontrado". Telas, catálogo, admin e transferências (com links HTTPS reais) funcionam.

---

## 4. IPA (instalação fora da App Store)

```bash
xcodebuild -project NexusStore.xcodeproj -scheme NexusStore \
           -configuration Release \
           -destination 'generic/platform=iOS' \
           -archivePath build/NexusStore.xcarchive archive

xcodebuild -exportArchive \
           -archivePath build/NexusStore.xcarchive \
           -exportOptionsPlist ExportOptions.plist \
           -exportPath build/ipa
```

`ExportOptions.plist` mínimo para distribuição via Ad Hoc com um Team de desenvolvedor:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>          <string>ad-hoc</string>
    <key>teamID</key>          <string>SEU_TEAM_ID</string>
    <key>signingStyle</key>    <string>automatic</string>
    <key>compileBitcode</key>  <false/>
</dict>
</plist>
```

Instale o `.ipa` via Apple Configurator, Xcode → **Devices and Simulators → Install**, ou TestFlight
(método `app-store-connect`).

---

## 5. TestFlight

1. Registre um App ID para o bundle no App Store Connect.
2. **Product → Archive** no Xcode (ou o comando acima).
3. **Distribute App → App Store Connect → Upload**.
4. Em App Store Connect, crie o app, preencha os metadados e envie o build para teste interno.

---

## 6. Verificações automatizadas (CI)

O workflow `.github/workflows/ci.yml` roda em cada push:

1. `Tools/verify_xcodeproj.py` — projeto sincronizado com os fontes.
2. `Tools/check_swift_style.py` — chaves/parênteses equilibrados, sem `TODO`/`fatalError` nas telas.
3. `Tools/ci/parse_all.sh` — **todos** os arquivos Swift passam pelo parser do compilador.
4. `swift build` + `swift test` (116 testes, Swift 6.4, Linux).
5. Integração com **servidor FTP real** (pyftpdlib): upload de 2 MiB verificado byte a byte.

O job de build do app iOS depende de macOS/Xcode. Neste repositório ele não é executado porque o
ambiente de desenvolvimento usado não tinha runners macOS disponíveis; os passos acima cobrem o que é
possível validar fora do Xcode. Ver `Docs/LIMITACOES.md`.

---

## 7. Configurações relevantes do projeto

| Configuração | Valor | Motivo |
|---|---|---|
| `IPHONEOS_DEPLOYMENT_TARGET` | `16.0` | `NavigationStack`, `Grid`, `presentationDetents` |
| `SWIFT_VERSION` | `5.0` (linguagem Swift 5) | Evita exigir modo Swift 6 estrito no app |
| `SWIFT_STRICT_CONCURRENCY` | `minimal` | Permite `@MainActor` + callbacks legados |
| `INFOPLIST_FILE` | `NexusStore/Info.plist` | Inclui `NSLocalNetworkUsageDescription` e ATS local |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.nexusstore.app` | Trocar se necessário |

---

## 8. Erros comuns

| Erro | Causa | Solução |
|---|---|---|
| `Signing for "NexusStore" requires a development team` | Team não configurado | Abra Signing & Capabilities e selecione seu Team |
| `No such module 'SwiftUI'` | Target errado | Compile o target **NexusStore** (app), não o pacote Swift |
| `Info.plist` duplicado | Chaves também em `INFOPLIST_KEY_*` | Mantenha as chaves somente no `Info.plist` |
| Descoberta não encontra nada no simulador | Limitação do simulador | Use um iPhone físico |
| `App Transport Security has blocked a cleartext HTTP resource` | URL HTTP pública | O app só aceita HTTPS público; HTTP é permitido apenas em rede local |

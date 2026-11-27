# Ética, direitos e responsabilidade

A Nexus Store é um **gerenciador pessoal de catálogo e transferência de arquivos para a rede local**.
Este documento deixa claro o que está — e o que não está — no escopo do projeto.

## O que o app faz

- Organiza um catálogo de jogos cadastrados pelo próprio usuário, com links HTTPS que o usuário fornece.
- Descobre um PS4 na mesma rede Wi-Fi (protocolo DDP público).
- Baixa um arquivo `.pkg` de um link informado pelo usuário, com verificação de espaço e retomada.
- Envia esse arquivo, por FTP, para um servidor que **o usuário** configurou no console.
- Mostra progresso, velocidade e erros reais.

## O que o app não faz

- Não contorna DRM, autenticação, bloqueios regionais ou qualquer proteção técnica do PlayStation.
- Não explora vulnerabilidades, não aplica patches e não habilita recursos pagos.
- Não inclui, distribui, indexa ou sugere fontes de jogos.
- Não converte, descriptografa ou modifica pacotes.
- Não instala jogos: transferir por FTP não instala nada.
- Não coleta telemetria nem envia dados a servidores nossos.

## Responsabilidade do usuário

Ao cadastrar um link e transferir um arquivo, o usuário declara que tem o direito de usar e
movimentar aquele conteúdo. Anexar ou enviar cópias de jogos comerciais sem licença é ilegal em
muitas jurisdições. O projeto não oferece orientação para obtenção de pacotes e não pode ser
responsabilizado pelo uso indevido.

A tela de administração exibe um aviso permanente: *"Você é responsável pelo conteúdo e pelos
direitos dos arquivos cadastrados."*

## Privacidade

- Senha do painel administrativo: hash SHA-256 com salt, no Keychain de arquivos do app (não sai do
  telefone).
- Catálogo, consoles e preferências: arquivos locais em `Application Support`.
- Rede: DDP (UDP 987), FTP (TCP) e HTTP local — tudo dentro da LAN. O download HTTPS vai para o host
  escolhido pelo usuário.
- Nenhum analytics, crash reporting remoto ou conta.

## Software de terceiros

O app não inclui bibliotecas de terceiros. As referências consultadas para o formato do protocolo DDP
foram implementações abertas amplamente documentadas; nenhum código delas foi copiado.

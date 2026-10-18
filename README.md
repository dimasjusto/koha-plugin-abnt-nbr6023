# Referência ABNT (NBR 6023) para Koha

Plugin para o [Koha](https://koha-community.org/) que gera a referência bibliográfica no padrão **ABNT NBR 6023:2025** a partir da catalogação MARC21 do registro, seja RDA ou AACR2.

- **OPAC:** a opção **ABNT** entra no menu **Citar**, em ordem alfabética, junto de APA, Chicago, Harvard e MLA.
- **Intranet:** botão **Referência ABNT** na barra de ferramentas do registro, com os avisos sobre a catalogação.
- **API REST:** `GET /api/v1/contrib/abnt/biblios/{biblionumber}/reference`.

O usuário só escolhe o registro e clica. O plugin identifica sozinho o tipo de documento (monografia, capítulo, artigo, periódico, legislação, evento) e as regras que se aplicam.

## Requisitos

- Koha **24.05 ou superior** (desenvolvido e testado no Koha 26).
- Plugins habilitados no `koha-conf.xml` (veja abaixo).

> [!WARNING]
> **Antes de instalar, ajuste o `koha-conf.xml`.**
> O Koha só aceita plugins quando estas duas linhas estão configuradas dentro do bloco `<config>` do arquivo `/etc/koha/sites/<instância>/koha-conf.xml`:
>
> ```xml
> <pluginsdir>/var/lib/koha/<instância>/plugins</pluginsdir>
> <enable_plugins>1</enable_plugins>
> ```
>
> - `<pluginsdir>` indica a pasta onde os plugins são instalados. Ela precisa existir e pertencer ao usuário da instância (por exemplo, `<instância>-koha`).
> - `<enable_plugins>` precisa estar com o valor `1`. Com `0`, o menu de plugins não aparece.
>
> Depois de alterar o arquivo, reinicie os serviços:
>
> ```bash
> sudo koha-plack --restart <instância>
> sudo systemctl restart memcached
> ```

> [!NOTE]
> Se o `koha-conf.xml` tiver `<plugins_restricted>1</plugins_restricted>`, o envio de arquivos `.kpz` pela interface fica bloqueado. Nesse caso, mude para `0` ou instale o plugin pela linha de comando.

## Instalação

1. Baixe o arquivo `.kpz` da versão mais recente na página [Releases](../../releases) deste repositório.
2. Na intranet do Koha, vá em **Administração › Plugins › Enviar plugin** e escolha o `.kpz`.
3. **Reinicie o Plack** para o Koha carregar a rota da API:

   ```bash
   sudo koha-plack --restart <instância>
   ```

4. Em **Ações › Configurar**, revise as opções. Os valores padrão já atendem à maioria das bibliotecas.

### Atualização

Envie o `.kpz` da nova versão pelo mesmo caminho e reinicie o Plack. A configuração salva é preservada.

## Configuração

| Opção | Padrão | O que faz |
|---|---|---|
| No OPAC, dentro do menu "Citar" | ligado | Insere "ABNT" no modal Citar. Desligado, ou num tema sem esse menu, aparece como link nas ações. |
| Nome no menu "Citar" | ABNT | Rótulo usado no modal. |
| Rótulo do botão | Referência ABNT | Rótulo na intranet e no link próprio do OPAC. |
| Modo padrão | Elementos essenciais | Ou "com elementos complementares" (descrição física, série, ISBN etc.). |
| Usuário pode alternar o modo | ligado | Mostra a escolha essencial/completa na janela da intranet. |
| Quatro ou mais autores | primeiro + *et al.* | Ou listar todos (8.1.1.1 / 8.1.1.2). |
| Disponível em (URL) | só recurso online | Ou incluir também a versão digitalizada (856 _1). |
| Título uniforme em legislação | ligado | `BRASIL. [Constituição (1988)].` |
| Abreviatura para "editor" (RDA) | org. | Usada quando o 245 $c não indica organizador, coordenador etc. |
| Frases locais de "não identificado" | — | Formas próprias da biblioteca para local e editora não identificados. |

## Como a referência é montada

O plugin lê o MARC21 e aplica a NBR 6023:2025. As decisões principais:

- **Tipo de documento:** pelo LDR/07 e pelo 773. Um `s` é periódico, um `b` com 773 é artigo e um `a` com 773 é capítulo; sem essas marcas, é monografia.
- **Autoria:** 1XX, ou, na falta dele, os 7XX conforme a função em `$e`/`$4`. Em obras coletivas sem 1XX, o 245 $c decide se a entrada é pelos organizadores, com a abreviatura que ele indicar: (org.), (coord.), (dir.). Os nomes seguem a ordem do 245 $c, e `[e outros]` gera *et al.*
- **Sem autor:** entrada pelo título, com a primeira palavra em maiúsculas (ou o artigo e a palavra seguinte).
- **Título:** a pontuação ISBD é retirada e o título principal vai em negrito. O `...` final vira `[...]`.
- **Edição:** a transcrição RDA é abreviada conforme o Anexo B (`2ª edição revista e atualizada` → `2. ed. rev. e atual.`).
- **Imprenta:** 264 _1 (ou 260). `[Lugar de publicação não identificado]` vira `[S. l.]`, `[editora não identificada]` vira `[s. n.]` e o copyright vira `c2015`.
- **Capítulos e artigos:** o documento no todo vem do registro-pai, localizado pelo 773 $w. Primeiro o plugin tenta a ligação nativa do Koha (`get_marc_host`), depois o número no 035 (útil para números de sistemas migrados) e por fim no 001. Sem registro-pai, usa os dados do próprio 773. O local do periódico que não for encontrado é omitido, e não substituído por `[S. l.]`.
- **URL (Disponível em / Acesso em):** só quando o registro descreve o recurso online, isto é, com 856 de 2º indicador `0`, ou 2º indicador branco/`8` com 008/23 = `o`, `q` ou `s`. O 856 _1 (versão digitalizada do impresso) e o 856 _2 (recurso relacionado) não entram.
- **Legislação:** jurisdição e título uniforme do 240 entre colchetes. Quando a lei sai em periódico (773), o negrito passa para o título do periódico.

## API

```
GET /api/v1/contrib/abnt/biblios/{biblionumber}/reference?mode=essencial|completo
```

Resposta:

```json
{
  "biblio_id": 123,
  "mode": "essencial",
  "type": "monografia",
  "html": "RANGEL, Paulo. <strong>Direito processual penal</strong>. 3. ed. rev., ampl. e atual. Rio de Janeiro: Lumen Juris, 2000.",
  "text": "RANGEL, Paulo. Direito processual penal. 3. ed. rev., ampl. e atual. Rio de Janeiro: Lumen Juris, 2000.",
  "warnings": []
}
```

Registros suprimidos no OPAC (942 $n = 1, com `OpacSuppression` ativa) só são devolvidos a usuários da equipe.

## Problemas comuns

- **O botão não aparece:** confira se o plugin está habilitado em Administração › Plugins e se o Plack foi reiniciado. Temas muito personalizados podem não ter o menu Citar (`#citeModal`) nem as ações (`#action`).
- **"Erro ao gerar a referência" ou erro 404 na API:** reinicie o Plack. A rota só é carregada no início do serviço.
- **O capítulo não encontra o livro:** verifique se o 773 $w do capítulo corresponde ao 001 ou ao 035 do registro-pai e se o índice de busca está atualizado.
- **Detalhes do erro:** `/var/log/koha/<instância>/plack-error.log`.

## Licença

[GNU GPL v3](LICENSE), a mesma licença do Koha.

## Autor

Sebastião Dimas Justo da Silva · [github.com/dimasjusto](https://github.com/dimasjusto)

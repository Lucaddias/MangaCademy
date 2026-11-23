# Teste de cache com dados reais no iPhone

## Quando usar

Use este roteiro quando o iPhone estiver conectado, desbloqueado e visível no Xcode. Ele compara a abertura do mesmo capítulo do NexusToons em dois modos: cache preservado entre encerramentos do processo e cache limpo antes de cada abertura.

## Dados usados e limite de carga

Antes da execução, o script lê apenas preferências de fonte do app original, sem copiar sua biblioteca. Só prossegue se a fonte selecionada (ou a última fonte usada quando o catálogo estiver em “todas”) for `nexustoons`, que é a única atualmente preparada aqui. Faz um único GET de pré-teste no Mac para confirmar HTTP 200 e a existência de uma obra segura com pelo menos 1.000 capítulos. O app isolado repete a consulta ao catálogo no iPhone, escolhe a obra segura com mais capítulos e busca os detalhes reais uma vez para gravar os capítulos no banco local de teste. Um cenário mede a lista longa usando esses capítulos; os outros abrem o primeiro capítulo e esperam a primeira imagem real terminar de carregar.

As medições usam cinco repetições após uma abertura de aquecimento por modo. Cada repetição do cenário de cache abre o mesmo capítulo. O endpoint que lista URLs de páginas é consultado em cada abertura; o que muda entre os modos é se as imagens da página já estão no cache local. Cinco amostras permitem comparar medianas, mas não sustentam um p95 estável. O teste não atualiza a biblioteca contra todas as fontes nem baixa capítulos em lote. Não há tentativas automáticas: qualquer resposta diferente de HTTP 200 no pré-teste interrompe a execução. Um bloqueio ou limite do provedor deve ser respeitado; não use WebView, proxy ou outra forma de contornar a proteção.

Os testes que usam `MeasurementFixtureSource` continuam úteis para verificar navegação offline determinística. Eles não representam carga, catálogo ou capítulos reais e não devem ser citados como evidência de performance do provedor.

## Pré-requisitos

- iPhone pareado, ligado, desbloqueado e conectado ao Mac.
- MihonReader original instalado; o roteiro confirma isso antes de compilar.
- Xcode com suporte ao iOS instalado no aparelho.
- Rede disponível para o catálogo, detalhes, endpoint de páginas e a primeira imagem.
- `curl`, `python3`, `xcrun` e `xcodebuild` disponíveis no Mac.

## Executar

Na raiz deste worktree:

```sh
bash scripts/run-device-cache-scenarios.sh
```

O script aceita `MIHONREADER_DEVICE_UDID` quando há mais de um iPhone conectado e `MIHONREADER_RESULTS_DIR` para escolher a pasta de resultados. Sem um UDID, exige exatamente um iPhone físico, pareado, conectado e iniciado.

Antes de instalar qualquer build, ele compila a variante `com.lucadias.MihonReader.PerformanceHarness` e confere o `CFBundleIdentifier` produzido. Se o ID não for exatamente esse, ele para. O app original usa `com.lucadias.MihonReader`; o script não o instala, remove ou altera. Também não desinstala a variante de teste ao final, para preservar os dados isolados e permitir inspeção posterior.

## Cenários

| Cenário | Comportamento | O que permanece salvo |
| --- | --- | --- |
| Cache preservado | Abre o capítulo para aquecimento; encerra e reabre o processo em cada repetição, sem limpar caches | Banco de teste, cache de imagens/páginas, metadados e cache HTTP; o download offline do capítulo escolhido é removido para forçar o fluxo pelo cache de imagens |
| Cache frio | Abre para aquecimento; antes de cada processo, limpa os caches de imagens/páginas, metadados e respostas HTTP | Banco de teste; o download offline do capítulo escolhido é removido; nenhum dado do app original |

O teste separado da lista longa percorre a tela usando os capítulos reais salvos no banco de teste e não faz uma nova requisição por capítulo. A variante usa esse snapshot local no detalhe, evitando procurar a mesma obra em MangaDex ou ComicK durante o teste.

Os dois cenários usam a mesma obra, capítulo, aparelho, build Release e fluxo de UI. O XCTest coleta tempo de relógio, CPU e memória para cada cenário. Deixe o aparelho na mesma condição de energia, brilho e rede ao comparar execuções separadas. Guarde os `.xcresult` juntos; não compare uma execução via Wi‑Fi com outra via rede móvel.

## Resultados e interrupção

O script mantém `warm-cache.xcresult`, `cold-cache.xcresult`, logs e DerivedData na pasta de resultados indicada ao final. Se `devicectl` não encontrar o iPhone conectado, o build não gera o bundle isolado esperado, ou o pré-teste receber erro, nenhum teste de UI é instalado ou iniciado.

Interrompa a execução se o provedor responder com bloqueio ou limite, se a conexão do dispositivo cair, ou se a variante de teste mostrar dados fora do cenário isolado. Não tente novamente automaticamente; corrija a condição e rode o roteiro manualmente depois.

## Última execução — 23 de novembro de 2026

Executada no iPhone 16 (`Iphone de Luca`), iOS 27.2.1 (24B156), Xcode 27.2 (27B52), build Release 1.0.0 (1), bundle isolado `com.lucadias.MihonReader.PerformanceHarness`. A conexão, build e cenário foram iguais nos três testes; foram cinco amostras por cenário, depois de um aquecimento. A obra pública selecionada tinha 3.862 capítulos reais.

| Cenário | Tempo mediano (faixa) | CPU mediana | Pico físico mediano |
| --- | --- | --- | --- |
| Lista de capítulos reais | 5,518 s (5,336–5,991) | 0,312 s | 15,47 MB |
| Cache preservado | 7,505 s (7,356–8,136) | 0,294 s | 18,22 MB |
| Cache frio | 7,462 s (7,359–7,733) | 0,296 s | 18,20 MB |

Com cinco amostras, não reportei p95. O tempo de cache frio ficou 43 ms abaixo do aquecido, diferença pequena diante da dispersão; esta execução não demonstra uma vantagem mensurável do cache no tempo total do fluxo. Cada abertura consulta o endpoint de URLs do capítulo, enquanto o cache retém os bytes das imagens. O XCTest confirmou a imagem real renderizada, mas a execução não coletou contadores de hits, bytes de rede nem uma trilha Instruments.

Os três UI tests passaram. Não executei nesta sessão busca e filtros por UI, Webtoon com páginas do provedor, download completo, atualização da biblioteca contra fontes externas, consumo de energia, FPS/hitches ou captura Instruments. O XCTest emitiu os avisos já conhecidos de QoS e da captura dos botões de volume; não houve falha de teste nem crash observado. A coleta opcional `devicectl diagnose` falhou depois de cada execução e deixou um arquivo parcial local no `.xcresult`; nenhum diagnóstico foi enviado à Apple.

Após os testes, os dois apps continuaram instalados: o original `com.lucadias.MihonReader` e a variante isolada `com.lucadias.MihonReader.PerformanceHarness`. A biblioteca e as preferências do app original não foram alteradas.

Os `.xcresult` desta execução ficaram em `/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/mihonreader-cache-20261123-133928`.

## Limpeza posterior

Não há limpeza automática do iPhone. Para remover a variante depois de guardar os `.xcresult`, confirme primeiro que o identificador é `com.lucadias.MihonReader.PerformanceHarness`. Nunca use o identificador normal do MihonReader para limpar dados. Os resultados ficam na pasta apontada pelo script e podem ser apagados separadamente depois de analisados.

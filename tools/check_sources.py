#!/usr/bin/env python3
"""
Testa as fontes do catálogo que têm motor iOS: abre a página de Populares de cada uma,
com as mesmas URLs dos motores Swift, e diz se ela responde e se o conteúdo ainda tem a
cara que o motor espera.

Resultados:
    ok          respondeu e tem obras
    vazia       respondeu no formato certo, mas sem obras (ex.: idioma sem títulos)
    cloudflare  bloqueada pela proteção anti-bot (o app também é bloqueado)
    fora do ar  DNS, conexão recusada, timeout ou erro 5xx
    html mudou  respondeu, mas sem os elementos que o motor procura
    http NNN    outro código HTTP (403, 404...)

Uso:
    python3 tools/check_sources.py                       # todas as fontes com motor
    python3 tools/check_sources.py --engine madara --lang pt-BR
    python3 tools/check_sources.py --out relatorio.md    # salva o relatório em Markdown
"""
import argparse
import collections
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse

CATALOG = os.path.join(os.path.dirname(__file__), "..", "Resources", "keiyoushi_catalog.json")
# O mesmo User-Agent do HTTPClient do app
USER_AGENT = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
              "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
CLOUDFLARE = ("cf-chl", "Just a moment", "challenge-platform")


def cls(name):
    """Mesmo critério do `cls()` do app: classe CSS como palavra inteira."""
    return re.compile(r'class="[^"]*(?<![\w-])' + re.escape(name) + r'(?![\w-])')


# Idiomas do Keiyoushi → códigos de cada site (os mesmos mapas dos motores Swift)
GLOBALCOMIX_LANGS = {"sq": "al", "pt-BR": "br", "zh-hans": "cn", "cs": "cz", "da": "dk", "fil": "fo",
                     "he": "iw", "ja": "jp", "ko": "kr", "ms": "my", "sv": "se", "uk": "ua"}
NAMICOMI_LANGS = {"pt-BR": "pt-br", "pt": "pt-pt", "es": "es-es"}
MANGABALL_LANGS = {"ca": "ca,ca-ad,ca-es,ca-fr,ca-it,ca-pt", "es": "es,es-ar,es-mx,es-es,es-la,es-419",
                   "it": "it,it-it", "is": "ib,ib-is,is", "ja": "ja,jp", "ko": "ko,kr", "kn": "kn,kn-in,kn-my,kn-sg,kn-tw",
                   "ml": "ml,ml-in,ml-my,ml-sg,ml-tw", "nl": "nl,nl-be", "pt-BR": "pt-br,pt-pt", "sr": "sr,sr-cyrl",
                   "th": "th,th-hk,th-kh,th-la,th-my,th-sg", "zh": "zh,zh-cn,zh-hk,zh-mo,zh-sg,zh-tw,cn"}
# O app usa uma fonte MangaDex só; aqui cada idioma do índice é testado com o código da API
MANGADEX_LANGS = {"es-419": "es-la", "fil": "tl", "zh-Hans": "zh", "zh-Hant": "zh-hk"}


class Probe:
    """Uma requisição e como reconhecer que o resultado tem obras."""

    def __init__(self, url, method="GET", body=None, headers=None, html=None, json_items=None):
        self.url = url
        self.method = method
        self.body = body
        self.headers = headers or {}
        self.html = html              # regex que precisa aparecer no HTML
        self.json_items = json_items  # função JSON -> lista de obras (None = formato errado)


def q(value):
    return urllib.parse.quote(value, safe="")


def probe_for(engine, source):
    base = source["baseUrl"]
    lang = source["lang"]
    kind = engine["type"]
    if kind == "madara":
        # O app tenta o admin-ajax antes; a página de arquivo é a alternativa que ele usa
        return Probe(f"{base}/{engine.get('mangaSubString') or 'manga'}/?m_orderby=views",
                     html=re.compile(r'class="[^"]*(?<![\w-])(page-item-detail|manga__item|c-tabs-item__content)(?![\w-])'))
    if kind == "mangathemesia":
        directory = engine.get("mangaUrlDirectory") or "/manga"
        directory = directory if directory.startswith("/") else "/" + directory
        return Probe(f"{base}{directory}/?page=1&order=popular", html=re.compile(r'class="[^"]*(?<![\w-])(bsx|imgu)(?![\w-])'))
    if kind == "zeistmanga":
        category = urllib.parse.quote(engine.get("mangaCategory") or "Series")
        return Probe(f"{base}/feeds/posts/default/-/{category}?alt=json&max-results=2",
                     json_items=lambda j: j.get("feed", {}).get("entry", []) if "feed" in j else None)
    if kind == "keyoapp":
        return Probe(f"{base}/series/", html=re.compile(r'href="[^"]*/series/[^"/]+'))
    if kind == "keyoappv2":
        return Probe(f"{base}/?_ajax=search&offset=0&sort=popular",
                     json_items=lambda j: re.findall(r'class="[^"]*\bgroup\b', j.get("html", "")) if "html" in j else None)
    if kind == "iken":
        api = engine.get("apiUrl") or base.replace("https://", "https://api.")
        return Probe(f"{api}/api/query?page=1&perPage={engine.get('perPage') or 18}&searchTerm=&orderBy=totalViews",
                     headers={"Referer": base + "/"}, json_items=lambda j: j.get("posts"))
    if kind == "pizzareader":
        return Probe(f"{engine.get('apiUrl') or base + '/api'}/comics", json_items=lambda j: j.get("comics"))
    if kind == "guya":
        return Probe(f"{base}/api/get_all_series/", json_items=lambda j: list(j.keys()) if isinstance(j, dict) else None)
    if kind == "foolslide":
        return Probe(f"{base}{engine.get('urlModifier') or ''}/directory/1/", html=cls("group"))
    if kind == "yiimanga":
        path = engine.get("popularPath")
        url = f"{base}/{path}/page/1/?order=views" if path else f"{base}/page/1/"
        return Probe(url, html=re.compile(r'class="[^"]*(?<![\w-])(latest-item|list-item)(?![\w-])'))
    if kind == "mmrcms":
        path = engine.get("popularPath")
        url = f"{base}/{path}" if path else f"{base}/filterList?page=1&sortBy=views&asc=false"
        return Probe(url, html=cls("media"))
    if kind == "mangacatalog":
        return Probe(base + "/", html=re.compile(r"-chapter-|/manga/"))
    if kind == "mangahub":
        gql = ('{ search(x: %s, q: "", genre: "all", mod: POPULAR, offset: 0) { rows { slug } } }'
               % (engine.get("mangaSource") or "m01"))
        return Probe("https://api.mghcdn.com/graphql", method="POST", body=json.dumps({"query": gql}).encode(),
                     headers={"Content-Type": "application/json", "Origin": base, "Referer": base + "/"},
                     json_items=lambda j: (j.get("data") or {}).get("search", {}).get("rows") if "data" in j else None)
    if kind == "mangadex":
        return Probe(f"https://api.mangadex.org/manga?limit=1&availableTranslatedLanguage[]={q(MANGADEX_LANGS.get(lang, lang.lower()))}",
                     json_items=lambda j: j.get("data"))
    if kind == "comick":
        return Probe(f"{base}/api/comics/top?day=7&type=follow", headers={"Referer": base + "/"},
                     json_items=lambda j: j.get("data"))
    if kind == "nexustoons":
        return Probe(f"{base}/api/mangas?page=1&limit=30&sortBy=views&sortOrder=desc",
                     json_items=lambda j: j.get("data") or j.get("mangas") or j.get("items"))
    if kind == "webtoons":
        code = lang.lower()
        return Probe(f"{base}/{code}/ranking/trending", html=cls("webtoon_list"),
                     headers={"Cookie": "ageGatePass=true; needGDPR=false"})
    if kind == "namicomi":
        code = NAMICOMI_LANGS.get(lang, lang.lower())
        return Probe(f"https://api.namicomi.com/title/search?limit=1&order[views]=desc&availableTranslatedLanguages[]={q(code)}",
                     json_items=lambda j: j.get("data"))
    if kind == "globalcomix":
        code = GLOBALCOMIX_LANGS.get(lang, lang)
        return Probe(f"https://api.globalcomix.com/v1/comics?lang_id[]={q(code)}&p=1",
                     headers={"x-gc-client": "gck_d0f170d5729446dcb3b55e6b3ebc7bf6", "x-gc-identmode": "cookie"},
                     json_items=lambda j: (j.get("payload") or {}).get("results"))
    if kind == "mangaball":
        codes = MANGABALL_LANGS.get(lang, lang.lower())
        return Probe(f"{base}/api/v1/title/search-advanced?page=1&limit=24&tag_mode=AND&adult_mode=all"
                     f"&lang={q(codes)}&sort_by=views&sort_order=desc", json_items=lambda j: j.get("data"))
    if kind == "comicfury":
        code = "pt" if lang == "pt-BR" else ("notext" if source["name"].endswith("(No Text)") else lang)
        return Probe(f"{base}/search.php?query=&page=1&language={q(code)}&sort=1", html=cls("webcomic-result"))
    return None


# Sites diferentes rodam em paralelo; o mesmo host recebe uma requisição por vez
_host_locks = collections.defaultdict(threading.Lock)
_host_locks_guard = threading.Lock()


def host_lock(url):
    with _host_locks_guard:
        return _host_locks[urllib.parse.urlsplit(url).netloc]


# Códigos de saída do curl que significam site inacessível
CURL_ERRORS = {6: "DNS não resolve", 7: "conexão recusada", 28: "timeout", 35: "falha no TLS",
               47: "redirecionamentos demais", 52: "resposta vazia", 56: "conexão caiu", 60: "certificado inválido"}


def fetch(probe, timeout):
    """Usa o curl do sistema: o Python do macOS (LibreSSL) não fala TLS 1.3 e falharia em vários sites."""
    headers = {"User-Agent": USER_AGENT, "Accept-Language": "en-US,en;q=0.9,pt-BR;q=0.8", **probe.headers}
    with tempfile.NamedTemporaryFile() as body_file:
        command = ["curl", "-sS", "-g", "-L", "--compressed", "--max-time", str(timeout), "-X", probe.method,
                   "-D", "-", "-o", body_file.name]
        for name, value in headers.items():
            command += ["-H", f"{name}: {value}"]
        if probe.body is not None:
            command += ["--data-binary", "@-"]
        command.append(probe.url)
        result = subprocess.run(command, input=probe.body, capture_output=True, timeout=timeout + 10)
        body = body_file.read(3_000_000).decode("utf-8", "replace")
    head = result.stdout.decode("latin-1", "replace")
    # Com redirecionamentos há vários blocos de cabeçalho: vale o último
    statuses = re.findall(r"^HTTP/[\d.]+ (\d{3})", head, re.M)
    return result.returncode, result.stderr.decode("utf-8", "replace").strip(), int(statuses[-1]) if statuses else 0, head, body


def check(engine, source, timeout):
    probe = probe_for(engine, source)
    if probe is None:
        return "sem teste", ""
    try:
        with host_lock(probe.url):
            code, error, status, head, text = fetch(probe, timeout)
    except subprocess.TimeoutExpired:
        return "fora do ar", "timeout"
    if code != 0:
        return "fora do ar", CURL_ERRORS.get(code, error[:120] or f"curl {code}")
    if "cf-mitigated" in head.lower() or any(marker in text for marker in CLOUDFLARE):
        return "cloudflare", probe.url
    if status >= 500:
        return "fora do ar", f"HTTP {status}"
    if status >= 300:
        return f"http {status}", probe.url
    if probe.json_items:
        try:
            items = probe.json_items(json.loads(text))
        except (ValueError, AttributeError, TypeError):
            return "html mudou", "resposta não é JSON"
        if items is None:
            return "html mudou", "JSON sem a lista de obras"
        return ("ok" if items else "vazia"), f"{len(items)} itens"
    if probe.html.search(text):
        return "ok", ""
    return "html mudou", probe.url


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default=CATALOG)
    ap.add_argument("--engine", help="só um motor (madara, mangathemesia...)")
    ap.add_argument("--lang", help="só um idioma (pt-BR, en...)")
    ap.add_argument("--timeout", type=float, default=20)
    ap.add_argument("--workers", type=int, default=24)
    ap.add_argument("--out", help="salva o relatório em Markdown")
    args = ap.parse_args()

    with open(args.catalog, encoding="utf-8") as f:
        extensions = json.load(f)["extensions"]
    jobs = [(ext, engine, source)
            for ext in extensions if (engine := ext.get("engine"))
            for source in ext["sources"]
            if (not args.engine or engine["type"] == args.engine) and (not args.lang or source["lang"] == args.lang)]
    print(f"Testando {len(jobs)} fontes...", file=sys.stderr)

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(check, engine, source, args.timeout): (ext, engine, source) for ext, engine, source in jobs}
        for done, future in enumerate(concurrent.futures.as_completed(futures), 1):
            ext, engine, source = futures[future]
            status, detail = future.result()
            results.append((status, engine["type"], source["lang"], source["name"], source["baseUrl"], detail))
            if done % 50 == 0:
                print(f"  {done}/{len(jobs)}", file=sys.stderr)

    by_status = collections.Counter(r[0] for r in results)
    by_engine = collections.defaultdict(collections.Counter)
    for status, engine, *_ in results:
        by_engine[engine][status] += 1
    statuses = sorted(by_status, key=lambda s: (s != "ok", -by_status[s]))

    lines = [f"# Saúde das fontes ({len(results)} com motor iOS)", ""]
    lines += [f"- **{status}**: {by_status[status]}" for status in statuses]
    lines += ["", "| Motor | " + " | ".join(statuses) + " |", "|---" * (len(statuses) + 1) + "|"]
    for engine in sorted(by_engine, key=lambda e: -sum(by_engine[e].values())):
        lines.append(f"| {engine} | " + " | ".join(str(by_engine[engine][s] or "") for s in statuses) + " |")
    lines += ["", "## Fontes com problema", "", "| Situação | Motor | Idioma | Fonte | Detalhe |", "|---|---|---|---|---|"]
    for status, engine, lang, name, base, detail in sorted(r for r in results if r[0] != "ok"):
        lines.append(f"| {status} | {engine} | {lang} | [{name}]({base}) | {detail.replace('|', '/')} |")
    report = "\n".join(lines) + "\n"

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(report)
        print(f"Relatório salvo em {args.out}", file=sys.stderr)
    else:
        print(report)
    print(" · ".join(f"{s}: {by_status[s]}" for s in statuses), file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())

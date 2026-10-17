#!/usr/bin/env python3
"""zotero-digest: turn a Zotero library into model-readable reading notes.

Two layers, so a paper is read by a model only once for the whole library:

  core digest   project-independent (design, findings, effect sizes, page-
                referenced quotes, limitations). Written once per item and
                stored as a child note in Zotero (tag `zotero-digest`) so it
                syncs with the library and is never regenerated. Falls back to
                a local file store when no Zotero API key is available.
  project layer relevance to your project's themes, how to cite the paper, and
                where your manuscript already cites it. Generated per project
                from the core digest plus your brief (about 2k tokens instead
                of a 30k-token PDF), written to literature/<collection>/.

    zotero-digest collections                  # list Zotero collections
    zotero-digest auth                         # check ZOTERO_API_KEY, show library id
    zotero-digest init --collection "my paper" # write zotero-digest.json + brief
    zotero-digest run                          # both layers for the project's collection
    zotero-digest library --collection X       # core layer only (or --all for the library)
    zotero-digest migrate literature/old-dir   # turn existing v0.1 digests into notes, no model calls
    zotero-digest index                        # rebuild INDEX.md from existing project files
    zotero-digest text <citekey> --outline     # page-aware text: outline, --section, --pages, --grep
    zotero-digest find "<terms>"               # search all stored digests, no model call
    zotero-digest check                        # lint: cited keys must exist in the .bib
    zotero-digest bib <citekey> --append-to x.bib   # clean BibTeX from Zotero, Better BibTeX key

Requirements: Zotero 7 running with the local API enabled (Settings > Advanced >
"Allow other applications on this computer to communicate with Zotero");
`pdftotext` (poppler); the `claude` CLI (default, runs on your Claude Code
subscription) or, with backend "api", the `anthropic` package. To store core
digests in Zotero itself: sync enabled and ZOTERO_API_KEY set to a key with
library write access (zotero.org/settings/keys).

Digests are derived from copyrighted PDFs: keep project output out of git.
"""
import argparse
import concurrent.futures
import datetime as dt
import glob
import hashlib
import html
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

__version__ = "0.2.0"

ZOTERO_LOCAL = "http://localhost:23119/api/users/0"
ZOTERO_WEB = "https://api.zotero.org"
STORAGE = pathlib.Path.home() / "Zotero" / "storage"
LOCAL_STORE = pathlib.Path(os.environ.get("ZOTERO_DIGEST_HOME", pathlib.Path.home() / ".local" / "share" / "zotero-digest")) / "notes"
CONFIG_NAME = "zotero-digest.json"
NOTE_TAG = "zotero-digest"
CORE_PROMPT_VERSION = 4      # bump when the core prompt/schema changes; stale notes are redone on --force
PROJECT_PROMPT_VERSION = 1   # bump when the project prompt/schema changes
MAX_CHARS = {"haiku": 180_000, "default": 700_000}
CLI_MODEL = "claude-sonnet-5"   # `claude --model` accepts full ids; the "sonnet" alias resolves to 4.6
API_MODEL = "claude-sonnet-5"

CORE_FIELDS = ["one_sentence", "paper_type", "research_question", "design", "sample", "measures", "analysis",
               "key_findings", "effect_sizes", "limitations", "quotable", "tags", "confidence_notes"]

DEFAULT_THEMES = [
    {"key": "relevance_to_project", "label": "the project",
     "description": "What the paper offers the project described in the brief: which claims it supports, "
                    "which it complicates, and which of the project's themes it speaks to. 'None' if nothing."}
]

CORE_SYSTEM_PROMPT = """You are a research assistant preparing structured reading notes on an academic paper. You will receive the paper's metadata and its extracted PDF text with [pdf page N] markers.

Write notes that let a colleague use the paper accurately without opening it, for any future project. Rules:
- Report what the paper actually says. Never invent results, numbers, or claims. If something is unclear or missing from the text, say so in confidence_notes.
- Prefer concrete numbers: sample sizes, effect sizes with their confidence or credible intervals, p-values, model types, measures, timeframes.
- Quote verbatim only, and give the pdf page marker nearest the quote.
- Plain scientific English. No praise of the paper, no filler.
- Return a single JSON object matching the requested schema and nothing else."""

PROJECT_SYSTEM_PROMPT = """You are a research assistant helping a team write a manuscript. You will receive structured reading notes on one paper (written earlier from the full text) and a brief describing the manuscript project. Judge the paper's relevance to the project's themes and say how it can and cannot be cited. Base every statement on the notes; do not add claims about the paper that the notes do not support. Plain scientific English, no filler. Return a single JSON object matching the requested schema and nothing else."""

CORE_SCHEMA = {
    "type": "object",
    "properties": {
        "one_sentence": {"type": "string", "description": "One sentence: what the paper did and found. Max 40 words."},
        "paper_type": {"type": "string", "enum": ["empirical", "review", "meta-analysis", "theory", "methods", "commentary", "dataset", "other"]},
        "research_question": {"type": "string"},
        "design": {"type": "string", "description": "Study design and timeframe, or 'n/a' for non-empirical papers."},
        "sample": {"type": "string", "description": "Who and how many, or 'n/a'."},
        "measures": {"type": "string", "description": "Key variables and instruments, or 'n/a'."},
        "analysis": {"type": "string", "description": "Analytic approach, or 'n/a'."},
        "key_findings": {"type": "array", "items": {"type": "string"}, "description": "3-8 findings, each with numbers where the paper gives them."},
        "effect_sizes": {"type": "array", "items": {"type": "string"}, "description": "Effect sizes with intervals and units, verbatim where possible. Empty if none."},
        "limitations": {"type": "array", "items": {"type": "string"}, "description": "Limitations the authors state, plus any obvious ones they do not."},
        "quotable": {"type": "array", "items": {"type": "object", "properties": {"quote": {"type": "string"}, "pdf_page": {"type": "integer"}}, "required": ["quote", "pdf_page"], "additionalProperties": False}, "description": "2-5 verbatim sentences worth citing, with the pdf page marker."},
        "tags": {"type": "array", "items": {"type": "string"}, "description": "3-6 short lowercase topic tags of 1-3 words."},
        "confidence_notes": {"type": "string", "description": "Text quality problems, truncation, missing sections, or ambiguities. 'None' if clean."},
    },
    "required": CORE_FIELDS, "additionalProperties": False,
}


def project_schema(themes):
    props = {t["key"]: {"type": "string", "description": t["description"]} for t in themes}
    props["how_to_use"] = {"type": "string", "description": "2-4 sentences: where and how the manuscript project could cite this paper, and any claim it must NOT be cited for."}
    return {"type": "object", "properties": props, "required": list(props), "additionalProperties": False}


# --------------------------------------------------------------------------- config
def load_config(path):
    cfg = {"collection": None, "out": None, "bib": [], "manuscripts": [], "brief": None,
           "themes": DEFAULT_THEMES, "model": None, "project_model": None, "backend": "cli", "jobs": 3}
    if path and pathlib.Path(path).exists():
        user = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
        cfg.update({k: v for k, v in user.items() if v is not None})
    for k in ("bib", "manuscripts"):
        if isinstance(cfg[k], str):
            cfg[k] = [cfg[k]]
    for t in cfg["themes"]:
        if not re.fullmatch(r"[a-z][a-z0-9_]*", t.get("key", "")) or t["key"] in CORE_FIELDS or t["key"] == "how_to_use":
            sys.exit(f"theme key must be a lowercase identifier not used by the core digest: {t}")
    return cfg


def slugify(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


INIT_BRIEF = """<!-- Describe the manuscript this literature feeds. The model reads this to judge each
paper's relevance and to suggest how it could be cited. Two or three paragraphs: the
research question, the design and measures, what the findings look like (if known),
and the themes the literature is used for. -->
"""

CLAUDE_SNIPPET = """## Literature: how to read a paper (zotero-digest)

`{out}/INDEX.md` lists every paper in the Zotero collection "{collection}" with a
one-line gist; `{out}/<citekey>.md` is its digest (design, findings, effect sizes,
verbatim quotes with pdf page numbers, relevance to this project, how it can be
cited, where the manuscript already cites it). Read in this order and stop as soon as
the question is answered:

1. `INDEX.md` to find candidate papers; `zotero-digest find "<terms>"` searches all
   digests in the library, not only this collection.
2. The paper's digest.
3. `zotero-digest text <citekey> --outline`, then `--section <name>` or `--pages A-B`
   for the part you need (a section is 1-5k tokens; a whole paper 15-30k).
4. `zotero-digest text <citekey> --grep "<number or phrase>"` to verify a specific
   figure with its pdf page before it goes into the manuscript.
5. The PDF itself only if the text is missing or garbled.

Cite only keys that exist in the bibliography: `zotero-digest check` lints every
cited key against the `.bib` (run it before rendering); add a paper the `.bib` lacks
with `zotero-digest bib <citekey> --append-to <file>.bib`, never by typing an entry.

Digests are model-written; treat them as a map, and verify numbers with step 4.
Regenerate or extend with `zotero-digest run` (needs Zotero running; skips
up-to-date papers; `--dry-run`, `--only <citekey>`, `--force`). `{out}/` is gitignored.
"""


def cmd_init(a):
    cfg_path = pathlib.Path(a.config or CONFIG_NAME)
    if cfg_path.exists() and not a.force:
        sys.exit(f"{cfg_path} exists; use --force to overwrite")
    collection = a.collection or "PASTE COLLECTION NAME"
    out = a.out or f"literature/{slugify(collection)}"
    cfg = {"collection": collection, "out": out, "bib": sorted(glob.glob("*.bib")) or ["references.bib"],
           "manuscripts": ["*.qmd", "*.Rmd", "*.md", "*.tex"], "brief": "literature/PROJECT_BRIEF.md",
           "themes": [dict(DEFAULT_THEMES[0])], "model": None, "project_model": None, "backend": "cli", "jobs": 3}
    cfg_path.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
    brief = pathlib.Path(cfg["brief"]); brief.parent.mkdir(parents=True, exist_ok=True)
    if not brief.exists():
        brief.write_text(INIT_BRIEF, encoding="utf-8")
    gi = pathlib.Path(".gitignore"); line = out.rstrip("/") + "/"
    if not gi.exists() or line not in gi.read_text(encoding="utf-8").split("\n"):
        with open(gi, "a", encoding="utf-8") as f:
            f.write(f"\n# zotero-digest output (derived from copyrighted PDFs)\n{line}\n")
    print(f"wrote {cfg_path} and {brief}; added {line} to .gitignore")
    print("Next: describe your project in the brief, edit the themes in the config if you want topic-specific "
          "relevance sections, then run `zotero-digest run --dry-run`.")
    print("\nPaste this into your CLAUDE.md so Claude Code uses the digests instead of PDFs:\n")
    print(CLAUDE_SNIPPET.format(out=out, collection=collection))


# --------------------------------------------------------------------------- Zotero local API (reads)
def _get_json(url, headers=None, timeout=30):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r), dict(r.headers)


def zget(path, **params):
    url = f"{ZOTERO_LOCAL}/{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
    try:
        return _get_json(url)[0]
    except Exception as e:
        sys.exit(f"Cannot reach Zotero's local API at {ZOTERO_LOCAL} ({e}). Is Zotero 7 running with "
                 "'Allow other applications on this computer to communicate with Zotero' enabled?")


def zget_all(path, **params):
    out, start = [], 0
    while True:
        page = zget(path, limit=100, start=start, **params)
        out += page
        if len(page) < 100:
            return out
        start += 100


def find_collection(name):
    cols = zget_all("collections")
    for c in cols:
        if c["data"]["name"].lower() == name.lower():
            return c
    names = ", ".join(sorted(c["data"]["name"] for c in cols))
    sys.exit(f"Collection {name!r} not found. Available: {names}")


def cmd_collections(a):
    for c in sorted(zget_all("collections"), key=lambda c: c["data"]["name"].lower()):
        print(f"{c['meta'].get('numItems', '?'):>5}  {c['data']['name']}")


def is_paper(rec):
    return rec["data"]["itemType"] not in ("attachment", "note", "annotation")


def papers_in(col_key=None):
    """Top-level items with their PDF path. col_key=None means the whole library."""
    recs = zget_all(f"collections/{col_key}/items") if col_key else zget_all("items")
    tops = [r for r in recs if is_paper(r)]
    atts = {}
    for r in recs:
        d = r["data"]
        if d["itemType"] == "attachment" and d.get("contentType") == "application/pdf":
            atts.setdefault(d.get("parentItem"), []).append(r)
    papers = []
    for t in tops:
        pdfs = atts.get(t["key"]) or [c for c in zget_all(f"items/{t['key']}/children")
                                      if c["data"]["itemType"] == "attachment" and c["data"].get("contentType") == "application/pdf"]
        papers.append({"item": t, "pdf": pdf_path(pdfs)})
    return papers


def pdf_path(pdf_atts):
    for a in pdf_atts:
        d = a["data"]
        if d.get("linkMode") == "linked_file" and d.get("path", "").startswith("/"):
            p = pathlib.Path(d["path"])
            if p.exists():
                return p
        folder = STORAGE / a["key"]
        if folder.is_dir():
            files = sorted(folder.glob("*.pdf"))
            if files:
                return files[0]
    return None


def citekey_for(item):
    d = item["data"]
    if d.get("citationKey"):
        return d["citationKey"]
    cr = d.get("creators") or [{}]
    au = re.sub(r"[^a-z]", "", (cr[0].get("lastName") or cr[0].get("name") or "anon").lower()) or "anon"
    year = (d.get("date") or "")[:4] or "nd"
    title = re.sub(r"[^a-z]", "", (d.get("title") or "").lower())[:12]
    return f"{au}{title.capitalize()}{year}"


def metadata(item):
    d = item["data"]
    authors = []
    for c in d.get("creators") or []:
        if c.get("lastName"):
            authors.append(f"{c.get('lastName')}, {c.get('firstName', '')}".strip(", "))
        elif c.get("name"):
            authors.append(c["name"])
    return {"title": d.get("title", ""), "authors": authors, "year": (d.get("date") or "")[:4],
            "journal": d.get("publicationTitle") or d.get("bookTitle") or d.get("proceedingsTitle") or "",
            "doi": d.get("DOI", ""), "url": d.get("url", ""), "item_type": d.get("itemType", ""),
            "abstract": d.get("abstractNote", ""), "zotero_key": item["key"]}


# --------------------------------------------------------------------------- item lookup and text access
def find_item(ref):
    """Resolve a citation key, Zotero item key, or DOI to a local-API item record."""
    hits = zget("items", q=ref, limit=25)
    if not any(is_paper(r) for r in hits):   # DOI and other fields; skip full-text hits on attachments
        hits = zget("items", q=ref, qmode="everything", itemType="-attachment", limit=50)
    for r in hits:
        d = r["data"]
        if is_paper(r) and ref.lower() in {str(x).lower() for x in (d.get("citationKey"), r["key"], d.get("DOI")) if x}:
            return r
    try:  # Better BibTeX JSON-RPC, if installed
        body = json.dumps({"jsonrpc": "2.0", "method": "item.search", "params": [ref], "id": 1}).encode()
        req = urllib.request.Request("http://localhost:23119/better-bibtex/json-rpc", data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            for hit in json.load(r).get("result", []):
                key = hit.get("id", "").rsplit("/", 1)[-1]
                if key and (hit.get("citation-key") == ref or len(hits) == 0):
                    return zget(f"items/{key}")
    except Exception:
        pass
    if re.fullmatch(r"[A-Z0-9]{8}", ref):
        try:
            return zget(f"items/{ref}")
        except SystemExit:
            pass
    sys.exit(f"No item found for {ref!r} (tried citation key, item key, DOI).")


def item_pages(item):
    """Page texts of the item's PDF: pdftotext (page-aware) or Zotero's full-text cache (single block)."""
    pdfs = [c for c in zget_all(f"items/{item['key']}/children")
            if c["data"]["itemType"] == "attachment" and c["data"].get("contentType") == "application/pdf"]
    path = pdf_path(pdfs)
    if path:
        try:
            raw = subprocess.run(["pdftotext", "-enc", "UTF-8", str(path), "-"], capture_output=True, text=True, check=True).stdout
            return [p.strip() for p in raw.split("\f")], str(path)
        except (FileNotFoundError, subprocess.CalledProcessError):
            pass
    for a in pdfs:
        cache = STORAGE / a["key"] / ".zotero-ft-cache"
        if cache.exists():
            return [cache.read_text(encoding="utf-8", errors="replace").strip()], str(cache) + " (no page boundaries)"
    sys.exit("No PDF text available for this item (no stored PDF, and no Zotero full-text cache).")


HEADING_RE = re.compile(
    r"^\s*(?:\d+(?:\.\d+)*\.?\s+|[IVX]+\.\s+)?(abstract|introduction|background|literature review|related work|theory|"
    r"theoretical (?:background|framework)|the present (?:study|research)|current study|hypotheses|method(?:s|ology)?|"
    r"materials and methods|participants|sample|procedure|measures|materials|design|data(?: analysis| collection)?|"
    r"analy(?:sis|ses|tic strategy)|statistical analys[ei]s|results|findings|discussion|general discussion|"
    r"limitations(?: and future (?:directions|research))?|conclusions?(?: and future work)?|implications|"
    r"references|bibliography|acknowledg(?:e)?ments?|appendix(?: [a-z0-9])?|supplementary materials?|supplement)"
    r"(?:[:.]\s*.{0,50})?\s*$", re.I)


def detect_sections(pages):
    """Heading candidates as (page_no, line_no_in_page, name); spans shorter than 300 chars are dropped."""
    cands = []
    for pn, text in enumerate(pages, 1):
        lines = text.split("\n")
        for ln, line in enumerate(lines):
            s = line.strip()
            if 3 <= len(s) <= 70 and not s.endswith(".") and HEADING_RE.match(s):
                cands.append((pn, ln, s))
    # compute span text for each candidate
    flat = []
    for i, (pn, ln, name) in enumerate(cands):
        end = cands[i + 1][:2] if i + 1 < len(cands) else (len(pages), None)
        flat.append({"page": pn, "line": ln, "name": name, "text": span_text(pages, (pn, ln), end)})
    return [c for c in flat if len(c["text"]) >= 300 or c is flat[-1]]


def span_text(pages, start, end):
    (sp, sl), (ep, el) = start, end
    out = []
    for pn in range(sp, ep + 1):
        lines = pages[pn - 1].split("\n") if pn - 1 < len(pages) else []
        a = sl if pn == sp else 0
        b = el if (pn == ep and el is not None) else len(lines)
        chunk = "\n".join(lines[a:b]).strip()
        if chunk:
            out.append(f"[pdf page {pn}]\n{chunk}")
    return "\n\n".join(out)


def cmd_text(a):
    item = find_item(a.ref)
    meta = metadata(item); ck = citekey_for(item)
    pages, src = item_pages(item)
    total = sum(len(p) for p in pages)
    print(f"# {ck}: {meta['title']} ({meta['year']}), {len(pages)} pdf page(s), ~{total // 4:,} tokens of text; source: {src}\n")
    out = ""
    if a.pages:
        m = re.fullmatch(r"(\d+)(?:-(\d+))?", a.pages)
        if not m:
            sys.exit("--pages takes N or N-M")
        lo, hi = int(m.group(1)), int(m.group(2) or m.group(1))
        out = "\n\n".join(f"[pdf page {pn}]\n{pages[pn - 1]}" for pn in range(lo, min(hi, len(pages)) + 1))
    elif a.section:
        secs = detect_sections(pages)
        hit = [s for s in secs if a.section.lower() in s["name"].lower()]
        if not hit:
            sys.exit(f"No section matching {a.section!r}. Sections: " + "; ".join(f"{s['name']} (p. {s['page']})" for s in secs))
        out = "\n\n".join(s["text"] for s in hit[:1])
    elif a.grep:
        pat = re.compile(a.grep, re.I)
        found = []
        for pn, text in enumerate(pages, 1):
            lines = text.split("\n")
            for i, line in enumerate(lines):
                if pat.search(line):
                    ctx = " ".join(l.strip() for l in lines[max(0, i - a.context): i + a.context + 1])
                    found.append(f"[pdf page {pn}] {ctx}")
        out = "\n".join(found) if found else f"(no match for {a.grep!r})"
    else:  # outline
        secs = detect_sections(pages)
        if not secs:
            out = "(no section headings detected; use --pages or --grep)"
        else:
            out = "Sections (heading, pdf page, ~tokens):\n" + "\n".join(
                f"  {s['name']:<50s} p. {s['page']:<4d} ~{len(s['text']) // 4:,}" for s in secs)
            out += ("\n\nRead one with --section <name>, a range with --pages A-B, or locate a number with --grep <term>. "
                    "Headings are detected heuristically; two-column layouts and custom headings can be missed or merged, "
                    "so a section that looks too large is best read by --pages.")
    if len(out) > a.max_chars:
        out = out[:a.max_chars] + f"\n\n[TRUNCATED at {a.max_chars:,} chars; narrow the request or raise --max-chars]"
    print(out)


def cmd_find(a):
    store = NoteStore()
    docs = store._load()
    terms = [t.lower() for t in re.findall(r"\w+", a.query) if len(t) > 2]
    if not terms:
        sys.exit("give a query with at least one word of 3+ letters")
    scored = []
    for key, d in docs.items():
        c = d["core"]; m = d.get("_meta", {})
        hay = " ".join([m.get("title", ""), c.get("one_sentence", ""), c.get("research_question", ""),
                        " ".join(c.get("key_findings", [])), " ".join(c.get("tags", [])),
                        " ".join(q.get("quote", "") for q in c.get("quotable", []))]).lower()
        score = sum(hay.count(t) for t in terms)
        if score and all(t in hay for t in terms) if a.all_terms else score:
            scored.append((score, m.get("citekey") or key, m.get("title", ""), c.get("one_sentence", ""), key))
    scored.sort(reverse=True)
    if not scored:
        print(f"no digest matches {a.query!r} ({len(docs)} digests searched)"); return
    print(f"{min(len(scored), a.limit)} of {len(scored)} matching digests ({len(docs)} searched; {store.kind()} store):\n")
    for score, ck, title, gist, key in scored[:a.limit]:
        print(f"- {ck} [{key}] score {score}\n  {title}\n  {gist}\n")


# --------------------------------------------------------------------------- bibliography
BIB_DROP_FIELDS = ("abstract", "file", "keywords", "urldate", "note", "language", "copyright", "annote")


def bibtex_for(item):
    """Clean BibTeX for one item from Zotero's export translator, keyed by its Better BibTeX citation key."""
    url = f"{ZOTERO_LOCAL}/items/{item['key']}?format=bibtex"
    with urllib.request.urlopen(url, timeout=30) as r:
        raw = r.read().decode("utf-8").strip()
    lines = [l for l in raw.split("\n") if not re.match(r"\s*(%s)\s*=" % "|".join(BIB_DROP_FIELDS), l)]
    entry = "\n".join(lines)
    ck = citekey_for(item)
    return re.sub(r"^@(\w+)\{[^,]+,", lambda m: f"@{m.group(1)}{{{ck},", entry, count=1)


def cmd_bib(a):
    cfg = resolve_settings(a)
    items = []
    if a.refs:
        items = [find_item(r) for r in a.refs]
    else:
        name = cfg["collection"]
        if not name:
            sys.exit("Give citation keys, or run inside a project (zotero-digest.json) to export its collection.")
        items = [p["item"] for p in papers_in(find_collection(name)["key"])]
    existing = bib_keys(cfg["bib"]) if cfg["bib"] else set()
    entries, added = [], 0
    for it in items:
        ck = citekey_for(it)
        if a.missing_only and resolve_bib_key(ck, existing):
            continue
        entries.append(bibtex_for(it)); added += 1
    text = "\n\n".join(entries) + ("\n" if entries else "")
    if a.append_to:
        with open(a.append_to, "a", encoding="utf-8") as f:
            f.write(("\n\n" if entries else "") + text)
        print(f"appended {added} entr{'y' if added == 1 else 'ies'} to {a.append_to}")
    else:
        sys.stdout.write(text)
        print(f"% {added} entr{'y' if added == 1 else 'ies'}", file=sys.stderr)


def cmd_check(a):
    """Lint citation keys: every key cited in the manuscripts must exist in the .bib; report keys that
    the library could supply, and bib entries the manuscripts never cite."""
    cfg = resolve_settings(a)
    files = a.files or [f for pat in cfg["manuscripts"] for f in sorted(glob.glob(pat))]
    keys = bib_keys(cfg["bib"])
    if not keys:
        sys.exit(f"No bibliography keys found in {cfg['bib']}; set `bib` in {CONFIG_NAME}.")
    cited = {}
    for f in files:
        text = pathlib.Path(f).read_text(encoding="utf-8", errors="replace")
        prose = "\n".join(re.split(r"```.*?```", text, flags=re.S))
        for m in re.finditer(r"(?<![\w@/:.-])@([A-Za-z][\w:.-]*?[\w])(?=[\s;,.\]\)\}]|$)", prose):
            k = m.group(1)
            if k.startswith(("fig-", "tbl-", "eq-", "sec-", "lst-")) or "." in k and "@" in prose[max(0, m.start() - 1):m.start()]:
                continue
            cited.setdefault(k, set()).add(pathlib.Path(f).name)
        for m in re.finditer(r"\\[a-zA-Z]*cite[a-zA-Z]*\*?(?:\[[^\]]*\])*\{([^}]*)\}", prose):
            for k in m.group(1).split(","):
                k = k.strip()
                if k:
                    cited.setdefault(k, set()).add(pathlib.Path(f).name)
    missing = sorted(k for k in cited if k not in keys and not re.search(r"\.(com|org|net|edu|uk|nl|se)$", k))
    print(f"{len(cited)} distinct keys cited in {len(files)} file(s); {len(keys)} entries in the bibliography")
    if not missing:
        print("OK: every cited key exists in the bibliography.")
    else:
        print(f"MISSING from the bibliography ({len(missing)}):")
        for k in missing:
            hint = ""
            try:
                hits = [r for r in zget("items", q=k, limit=5) if is_paper(r)]
                if not hits:
                    hits = [r for r in zget("items", q=k, qmode="everything", itemType="-attachment", limit=10) if is_paper(r)]
                if hits:
                    hint = "  <- in Zotero as " + ", ".join(citekey_for(h) for h in hits[:3]) + "  (zotero-digest bib <key> --append-to <bib>)"
            except SystemExit:
                pass
            print(f"  {k}  (in {', '.join(sorted(cited[k]))}){hint}")
    if a.unused:
        unused = sorted(k for k in keys if k not in cited and not any(resolve_bib_key(c, {k}) for c in cited))
        print(f"\nBibliography entries never cited ({len(unused)}):\n  " + "\n  ".join(unused))
    sys.exit(1 if missing else 0)


# --------------------------------------------------------------------------- note store (core digests)
def note_html(core, meta_info, title):
    e = html.escape
    L = [f"<h1>Reading notes: {e(title)}</h1>", f"<p><b>In one sentence.</b> {e(core['one_sentence'])}</p>",
         "<h2>Research question</h2>", f"<p>{e(core['research_question'])}</p>", "<h2>Design</h2>", "<ul>"]
    for k in ("design", "sample", "measures", "analysis"):
        L.append(f"<li><b>{k.capitalize()}:</b> {e(core[k])}</li>")
    L += ["</ul>", "<h2>Key findings</h2>", "<ul>"] + [f"<li>{e(f)}</li>" for f in core["key_findings"]] + ["</ul>"]
    if core["effect_sizes"]:
        L += ["<h2>Effect sizes</h2>", "<ul>"] + [f"<li>{e(x)}</li>" for x in core["effect_sizes"]] + ["</ul>"]
    L += ["<h2>Limitations</h2>", "<ul>"] + [f"<li>{e(x)}</li>" for x in core["limitations"]] + ["</ul>"]
    if core["quotable"]:
        L += ["<h2>Quotable (verbatim; pdf page numbers)</h2>", "<ul>"] + \
             [f"<li>&ldquo;{e(q['quote'])}&rdquo; (pdf p. {q['pdf_page']})</li>" for q in core["quotable"]] + ["</ul>"]
    L += ["<h2>Notes on this digest</h2>", f"<p>{e(core['confidence_notes'])}</p>",
          f"<p><i>zotero-digest {__version__}, model {e(str(meta_info.get('model')))}, {e(str(meta_info.get('digested_at')))}, "
          f"prompt v{meta_info.get('prompt_version')}. Tags: {e(', '.join(core['tags']))}</i></p>",
          "<h2>Machine-readable</h2>",
          "<pre>" + e(json.dumps({"core": core, "_meta": meta_info}, ensure_ascii=False)) + "</pre>"]
    return "\n".join(L)


def parse_note(note_html_text):
    blocks = re.findall(r"<pre[^>]*>(.*?)</pre>", note_html_text, flags=re.S)
    for b in reversed(blocks):
        txt = html.unescape(re.sub(r"<[^>]+>", "", b)).strip()
        try:
            d = json.loads(txt)
            if "core" in d and "_meta" in d:
                return d
        except ValueError:
            continue
    return None


_SSL_CONTEXT = None


def ssl_context():
    """Default TLS context, with certifi's bundle when the interpreter ships none (python.org macOS builds)."""
    global _SSL_CONTEXT
    if _SSL_CONTEXT is None:
        import ssl
        ctx = ssl.create_default_context()
        if not ctx.get_ca_certs():
            try:
                import certifi
                ctx = ssl.create_default_context(cafile=certifi.where())
            except ImportError:
                pass
        _SSL_CONTEXT = ctx
    return _SSL_CONTEXT


class WebAPI:
    def __init__(self, key):
        self.key = key
        info, _ = self._req("GET", "/keys/current")
        self.user_id = info["userID"]
        self.username = info.get("username", "")
        acc = info.get("access", {}).get("user", {})
        self.can_write = bool(acc.get("write")) and bool(acc.get("notes", True))

    def _req(self, method, path, body=None, headers=None):
        h = {"Zotero-API-Key": self.key, "Zotero-API-Version": "3"}
        if body is not None:
            h["Content-Type"] = "application/json"
        h.update(headers or {})
        data = json.dumps(body).encode("utf-8") if body is not None else None
        for attempt in range(5):
            req = urllib.request.Request(ZOTERO_WEB + path, data=data, headers=h, method=method)
            try:
                with urllib.request.urlopen(req, timeout=60, context=ssl_context()) as r:
                    raw = r.read()
                    return (json.loads(raw) if raw else None), dict(r.headers)
            except urllib.error.HTTPError as err:
                if err.code in (429, 503) and attempt < 4:
                    time.sleep(float(err.headers.get("Retry-After") or err.headers.get("Backoff") or 5))
                    continue
                raise RuntimeError(f"Zotero web API {method} {path} -> {err.code}: {err.read()[:300]!r}")
            except urllib.error.URLError as err:
                if "CERTIFICATE_VERIFY_FAILED" in str(err):
                    raise RuntimeError("TLS certificate verification failed: this Python has no root certificates. "
                                       "Run `pip install certifi`, or on macOS the python.org installer's "
                                       "'Install Certificates.command', or use Homebrew Python.")
                raise RuntimeError(f"Zotero web API {method} {path}: {err}")


    def get_all(self, path, **params):
        out, start = [], 0
        while True:
            q = dict(params, limit=100, start=start)
            page, _ = self._req("GET", f"{path}?{urllib.parse.urlencode(q)}")
            out += page
            if len(page) < 100:
                return out
            start += 100

    def digest_notes(self):
        """All zotero-digest notes in the library, keyed by parent item key."""
        notes = self.get_all(f"/users/{self.user_id}/items", tag=NOTE_TAG, itemType="note")
        return {n["data"]["parentItem"]: n for n in notes if n["data"].get("parentItem")}

    def write_note(self, parent_key, note_html_text, existing=None):
        tags = [{"tag": NOTE_TAG}, {"tag": f"{NOTE_TAG}:v{CORE_PROMPT_VERSION}"}]
        if existing:
            body = {"note": note_html_text, "tags": tags}
            self._req("PATCH", f"/users/{self.user_id}/items/{existing['key']}", body,
                      {"If-Unmodified-Since-Version": str(existing["version"])})
            return existing["key"]
        resp, _ = self._req("POST", f"/users/{self.user_id}/items",
                            [{"itemType": "note", "parentItem": parent_key, "note": note_html_text, "tags": tags}])
        if resp.get("failed"):
            raise RuntimeError(f"note creation failed: {resp['failed']}")
        return resp["successful"]["0"]["key"]


class NoteStore:
    """Core digests: in Zotero (child notes, via web API for writes and local/web API for reads),
    or in a local folder when no API key is configured."""

    def __init__(self, require_zotero=False):
        key = os.environ.get("ZOTERO_API_KEY")
        self.web = None
        if key:
            try:
                self.web = WebAPI(key)
            except Exception as e:
                sys.exit(f"ZOTERO_API_KEY is set but the web API rejected it: {e}")
            if not self.web.can_write:
                sys.exit("The Zotero API key has no write access to notes; create one with library write access at zotero.org/settings/keys.")
        elif require_zotero:
            sys.exit("Set ZOTERO_API_KEY (zotero.org/settings/keys, library write access) to store digests in Zotero.")
        else:
            LOCAL_STORE.mkdir(parents=True, exist_ok=True)
            print(f"note: ZOTERO_API_KEY not set; core digests are kept in {LOCAL_STORE} instead of Zotero notes.", file=sys.stderr)
        self._cache = None

    def kind(self):
        return "zotero" if self.web else "local"

    def _load(self):
        if self._cache is not None:
            return self._cache
        found = {}
        if self.web:
            # Local API first (fast, no rate limit), then web API for notes not yet synced down.
            for n in zget_all("items", tag=NOTE_TAG, itemType="note"):
                p = n["data"].get("parentItem")
                if p:
                    found[p] = {"src": "local", "key": n["key"], "version": n["data"]["version"], "html": n["data"]["note"]}
            for p, n in self.web.digest_notes().items():
                if p not in found or n["data"]["version"] > found[p]["version"]:
                    found[p] = {"src": "web", "key": n["key"], "version": n["data"]["version"], "html": n["data"]["note"]}
            parsed = {}
            for p, n in found.items():
                d = parse_note(n["html"])
                if d:
                    d["_note"] = {"key": n["key"], "version": n["version"]}
                    parsed[p] = d
            self._cache = parsed
        else:
            self._cache = {}
            for f in LOCAL_STORE.glob("*.json"):
                self._cache[f.stem] = json.loads(f.read_text(encoding="utf-8"))
        return self._cache

    def get(self, item_key):
        return self._load().get(item_key)

    def put(self, item_key, core, meta_info, title):
        doc = {"core": core, "_meta": meta_info}
        if self.web:
            existing = (self._load().get(item_key) or {}).get("_note")
            note_key = self.web.write_note(item_key, note_html(core, meta_info, title), existing)
            doc["_note"] = {"key": note_key, "version": None}
        else:
            (LOCAL_STORE / f"{item_key}.json").write_text(json.dumps(doc, indent=1, ensure_ascii=False), encoding="utf-8")
        self._load()[item_key] = doc
        return doc


def cmd_auth(a):
    key = os.environ.get("ZOTERO_API_KEY")
    if not key:
        sys.exit("ZOTERO_API_KEY is not set. Create a key with library write access at https://www.zotero.org/settings/keys "
                 "and export it, e.g. `export ZOTERO_API_KEY=...` in your shell profile.")
    w = WebAPI(key)
    print(f"key ok: user {w.username} (library id {w.user_id}); write access: {'yes' if w.can_write else 'NO'}")
    n = len(w.digest_notes())
    print(f"{n} zotero-digest note(s) in the library")


# --------------------------------------------------------------------------- project cross-references
def bib_keys(paths):
    keys = set()
    for pat in paths:
        for f in glob.glob(pat):
            keys |= set(re.findall(r"^@\w+\{([^,\s]+),", pathlib.Path(f).read_text(encoding="utf-8", errors="replace"), flags=re.M))
    return keys


def resolve_bib_key(citekey, keys):
    if citekey in keys:
        return citekey
    cands = sorted(k for k in keys if re.fullmatch(re.escape(citekey) + r"[a-z]?", k))
    return cands[0] if cands else None


def manuscript_uses(citekey, patterns, max_snippets=3):
    if not citekey:
        return 0, []
    n, snippets = 0, []
    pat = re.compile(r"(?<![\w-])@" + re.escape(citekey) + r"\b|\\[a-zA-Z]*cite[a-zA-Z]*\*?(?:\[[^\]]*\])*\{[^}]*\b" + re.escape(citekey) + r"\b[^}]*\}")
    for pattern in patterns:
        for f in sorted(glob.glob(pattern)):
            text = pathlib.Path(f).read_text(encoding="utf-8", errors="replace")
            prose = "\n".join(re.split(r"```.*?```", text, flags=re.S))
            for m in pat.finditer(prose):
                n += 1
                s = max(prose.rfind(". ", 0, m.start()), prose.rfind("\n", 0, m.start())) + 1
                e = prose.find(". ", m.end()); e = len(prose) if e == -1 else e + 1
                snip = re.sub(r"\s+", " ", prose[s:e]).strip()
                if snip and snip not in snippets and len(snippets) < max_snippets:
                    snippets.append(f"{pathlib.Path(f).name}: {snip[:400]}")
    return n, snippets


# --------------------------------------------------------------------------- PDF text
def pdf_text(path, model=""):
    max_chars = MAX_CHARS["haiku"] if "haiku" in model else MAX_CHARS["default"]
    try:
        raw = subprocess.run(["pdftotext", "-enc", "UTF-8", str(path), "-"], capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        sys.exit("pdftotext not found. Install poppler (macOS: brew install poppler; Debian/Ubuntu: apt install poppler-utils).")
    pages = raw.split("\f")
    parts = [f"[pdf page {i}]\n{p.strip()}" for i, p in enumerate(pages, 1) if p.strip()]
    text = "\n\n".join(parts)
    truncated = len(text) > max_chars
    return (text[:max_chars] + "\n\n[TEXT TRUNCATED HERE]" if truncated else text), truncated, len(pages)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------- model backends
def core_prompt(meta, text, truncated):
    head = "\n".join(f"{k}: {v}" for k, v in [("Title", meta["title"]), ("Authors", "; ".join(meta["authors"])),
                                             ("Year", meta["year"]), ("Venue", meta["journal"]), ("DOI", meta["doi"]),
                                             ("Zotero abstract", meta["abstract"] or "(none)")])
    note = "\nNOTE: the PDF text was truncated; say so in confidence_notes.\n" if truncated else ""
    body = text or "(No PDF text available. Work from the metadata and abstract only, and say so in confidence_notes.)"
    return (f"PAPER METADATA\n{head}\n{note}\nPAPER TEXT\n{body}\n\nReturn one JSON object with exactly these fields:\n"
            f"{json.dumps(CORE_SCHEMA['properties'], indent=1)}\nAll fields are required. Output the JSON only, no code fences.")


def project_prompt(meta, core, brief, themes, schema):
    head = f"Title: {meta['title']}\nAuthors: {'; '.join(meta['authors'])}\nYear: {meta['year']}\nVenue: {meta['journal']}"
    return (f"PAPER\n{head}\n\nREADING NOTES (written from the full text)\n{json.dumps(core, indent=1, ensure_ascii=False)}\n\n"
            f"MANUSCRIPT PROJECT\n{brief}\n\nReturn one JSON object with exactly these fields:\n"
            f"{json.dumps(schema['properties'], indent=1)}\nAll fields are required. Output the JSON only, no code fences.")


def parse_json_reply(s):
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s.strip(), flags=re.S)
    start, end = s.find("{"), s.rfind("}")
    return json.loads(s[start:end + 1])


def run_cli(system_prompt, user_prompt, model, schema):
    """Headless `claude -p`; runs in an empty temp dir so no project CLAUDE.md is loaded."""
    with tempfile.TemporaryDirectory() as td:
        # --tools "" drops the tool definitions from the request (about 20k tokens of fixed overhead per call).
        cmd = ["claude", "-p", "--model", model, "--output-format", "json", "--no-session-persistence",
               "--system-prompt", system_prompt, "--tools", ""]
        try:
            r = subprocess.run(cmd, input=user_prompt, capture_output=True, text=True, cwd=td, timeout=900)
        except FileNotFoundError:
            sys.exit("`claude` CLI not found. Install Claude Code, or use --backend api with the anthropic package.")
    if r.returncode != 0:
        raise RuntimeError(f"claude exited {r.returncode}: {r.stderr[-800:]}")
    env = json.loads(r.stdout)
    if env.get("is_error"):
        raise RuntimeError(f"claude error: {env.get('result')}")
    return parse_json_reply(env["result"]), float(env.get("total_cost_usd") or 0.0), env.get("usage", {})


def run_api(system_prompt, user_prompt, model, schema):
    try:
        import anthropic
    except ImportError:
        sys.exit("backend 'api' needs `pip install anthropic` and an API credential (ANTHROPIC_API_KEY).")
    client = anthropic.Anthropic()
    resp = client.messages.create(model=model, max_tokens=8000,
                                  system=[{"type": "text", "text": system_prompt, "cache_control": {"type": "ephemeral"}}],
                                  messages=[{"role": "user", "content": user_prompt}],
                                  output_config={"format": {"type": "json_schema", "schema": schema}})
    text = next(b.text for b in resp.content if b.type == "text")
    u = resp.usage
    return json.loads(text), 0.0, {"input_tokens": u.input_tokens, "output_tokens": u.output_tokens}


def call_model(backend, system_prompt, user_prompt, model, schema):
    runner = run_cli if backend == "cli" else run_api
    try:
        return runner(system_prompt, user_prompt, model, schema)
    except Exception as e:  # one retry
        print(f"  retry: {str(e)[:120]}", file=sys.stderr)
        return runner(system_prompt, user_prompt, model, schema)


def tokens_in(usage):
    return sum(usage.get(k, 0) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))


# --------------------------------------------------------------------------- core layer
def core_up_to_date(doc, pdf_hash):
    return bool(doc) and doc["_meta"].get("pdf_sha256") == pdf_hash and doc["_meta"].get("prompt_version") == CORE_PROMPT_VERSION


def digest_core(store, papers, cfg, a):
    """Ensure every paper has a core digest in the store. Returns {item_key: doc}."""
    model = cfg["model"] or (CLI_MODEL if cfg["backend"] == "cli" else API_MODEL)
    todo, have = [], {}
    for p in papers:
        key = p["item"]["key"]
        pdf_hash = sha256_file(p["pdf"]) if p["pdf"] else None
        doc = store.get(key)
        ck = citekey_for(p["item"])
        wanted = a.only is None or ck in a.only
        if wanted and (a.force or not core_up_to_date(doc, pdf_hash)):
            todo.append((p, pdf_hash))
        elif doc:
            have[key] = doc
    if a.limit is not None:
        todo = todo[:a.limit]
    print(f"core layer ({store.kind()} store): {len(todo)} to digest, {len(have)} already present")
    if a.dry_run:
        for p, _ in todo:
            print(f"  {citekey_for(p['item']):45s} {'PDF' if p['pdf'] else 'no pdf'}  {p['item']['data'].get('title', '')[:70]}")
        return have

    def work(job):
        p, pdf_hash = job
        meta = metadata(p["item"])
        text, truncated, n_pages = pdf_text(p["pdf"], model) if p["pdf"] else ("", False, 0)
        core, cost, usage = call_model(cfg["backend"], CORE_SYSTEM_PROMPT, core_prompt(meta, text, truncated), model, CORE_SCHEMA)
        core = {k: core[k] for k in CORE_FIELDS}
        meta_info = {"pdf": str(p["pdf"]) if p["pdf"] else None, "pdf_sha256": pdf_hash, "pdf_pages": n_pages,
                     "truncated": truncated, "model": model, "backend": cfg["backend"], "prompt_version": CORE_PROMPT_VERSION,
                     "digested_at": dt.datetime.now().strftime("%Y-%m-%d"), "cost_usd": cost, "usage": usage,
                     "citekey": citekey_for(p["item"]), "title": meta["title"]}
        doc = store.put(p["item"]["key"], core, meta_info, meta["title"])
        return p["item"]["key"], doc, cost, usage

    total = 0.0
    with concurrent.futures.ThreadPoolExecutor(max_workers=int(cfg["jobs"])) as ex:
        futures = {ex.submit(work, job): citekey_for(job[0]["item"]) for job in todo}
        for fut in concurrent.futures.as_completed(futures):
            ck = futures[fut]
            try:
                key, doc, cost, usage = fut.result()
            except Exception as e:
                print(f"FAILED {ck}: {str(e)[:300]}", file=sys.stderr); continue
            have[key] = doc; total += cost
            print(f"  core {ck:45s} in={tokens_in(usage)} out={usage.get('output_tokens', '?')} ${cost:.3f}", flush=True)
    if todo:
        print(f"core layer: this run ${total:.2f} (API-equivalent)")
    return have


# --------------------------------------------------------------------------- project layer
def project_hash(doc, brief, themes, model):
    return sha256_text(json.dumps([doc["core"], brief, themes, model, PROJECT_PROMPT_VERSION], sort_keys=True))


def render_md(citekey, meta, core, proj, xref, m, themes):
    fm = ["---", f"citekey: {citekey}", f"title: {json.dumps(meta['title'], ensure_ascii=False)}",
          f"authors: {json.dumps('; '.join(meta['authors']), ensure_ascii=False)}", f"year: {json.dumps(meta['year'])}",
          f"venue: {json.dumps(meta['journal'], ensure_ascii=False)}", f"doi: {json.dumps(meta['doi'])}",
          f"paper_type: {core['paper_type']}", f"tags: [{', '.join(json.dumps(t, ensure_ascii=False) for t in core['tags'])}]",
          f"in_bibliography: {'true' if xref['in_bib'] else 'false'}", f"bib_key: {json.dumps(xref['bib_key'] or '')}",
          f"manuscript_citations: {xref['n_cites']}", f"pdf_available: {'true' if m['pdf'] else 'false'}",
          f"digested: {m['digested_at']} by {m['model']} (core prompt v{m['prompt_version']}, project layer v{PROJECT_PROMPT_VERSION})", "---"]
    L = fm + ["", f"# {meta['title']}", "",
              f"**{'; '.join(meta['authors'])}** ({meta['year']}). *{meta['journal']}*." + (f" doi:{meta['doi']}" if meta['doi'] else ""), "",
              f"**In one sentence.** {core['one_sentence']}", "", "## Research question", core["research_question"], "",
              "## Design", f"- **Design:** {core['design']}", f"- **Sample:** {core['sample']}",
              f"- **Measures:** {core['measures']}", f"- **Analysis:** {core['analysis']}", "",
              "## Key findings"] + [f"- {f}" for f in core["key_findings"]] + [""]
    if core["effect_sizes"]:
        L += ["## Effect sizes"] + [f"- {e}" for e in core["effect_sizes"]] + [""]
    for t in themes:
        L += [f"## Relevance to {t['label']}", proj.get(t["key"], ""), ""]
    L += ["## Limitations"] + [f"- {x}" for x in core["limitations"]] + [""]
    if core["quotable"]:
        L += ["## Quotable (verbatim; pdf page numbers, not journal pages)"] + \
             [f"- \"{q['quote']}\" (pdf p. {q['pdf_page']})" for q in core["quotable"]] + [""]
    L += ["## How to use in the manuscript", proj["how_to_use"], ""]
    if xref["snippets"]:
        L += [f"## Current use in the manuscript ({xref['n_cites']} citation{'s' if xref['n_cites'] != 1 else ''})"] + [f"- {s}" for s in xref["snippets"]] + [""]
    elif xref["in_bib"]:
        L += ["## Current use in the manuscript", "In the bibliography but not cited in the manuscript text.", ""]
    else:
        L += ["## Current use in the manuscript", "Not in the bibliography.", ""]
    L += ["## Notes on this digest", core["confidence_notes"], ""]
    return "\n".join(L)


def render_index(col_name, rows):
    L = [f"# Literature digests: {col_name}", "",
         "Model-written reading notes (see each digest's frontmatter for the model) for the papers in this Zotero "
         "collection. Each row links to a digest with design, findings, effect sizes, quotable sentences with pdf page "
         "numbers, and guidance on how the paper can be cited. **Read this index first, then open only the digests you "
         "need; verify any number you intend to publish against the PDF.** Regenerate with `zotero-digest run`.", "",
         "| citekey | year | type | gist | tags | pdf | cited |", "|---|---|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: (r["year"], r["citekey"])):
        L.append(f"| [{r['citekey']}]({r['citekey']}.md) | {r['year']} | {r['paper_type']} | {r['one_sentence'].replace('|', '/')} | "
                 f"{', '.join(r['tags'])} | {'yes' if r['pdf'] else 'no'} | {r['n_cites']} |")
    L += ["", f"{len(rows)} papers. Generated {dt.datetime.now():%Y-%m-%d %H:%M}."]
    return "\n".join(L) + "\n"


def project_layer(papers, docs, cfg, out, a):
    themes, schema = cfg["themes"], project_schema(cfg["themes"])
    model = cfg["project_model"] or cfg["model"] or (CLI_MODEL if cfg["backend"] == "cli" else API_MODEL)
    brief_path = pathlib.Path(cfg["brief"]) if cfg["brief"] else None
    brief = brief_path.read_text(encoding="utf-8") if brief_path and brief_path.exists() else ""
    brief = re.sub(r"<!--.*?-->", "", brief, flags=re.S).strip()
    if not brief:
        print(f"WARNING: no project brief at {brief_path}; relevance and how-to-use notes will be generic.", file=sys.stderr)
    keys_in_bib = bib_keys(cfg["bib"])
    todo, rows = [], []
    for p in papers:
        key = p["item"]["key"]; doc = docs.get(key)
        if not doc:
            continue
        ck = citekey_for(p["item"]); jpath = out / f"{ck}.json"
        h = project_hash(doc, brief, themes, model)
        existing = json.loads(jpath.read_text(encoding="utf-8")) if jpath.exists() else None
        if existing and existing.get("_meta", {}).get("project_hash") == h and not a.force:
            # refresh the cheap, model-free cross-references so citation counts stay current
            rows.append(refresh_xref(p, doc, existing, cfg, out, keys_in_bib, themes))
        else:
            todo.append((p, doc, h))
    print(f"project layer: {len(todo)} to generate, {len(rows)} up to date")
    if a.dry_run:
        return
    def work(job):
        p, doc, h = job
        meta = metadata(p["item"]); ck = citekey_for(p["item"])
        proj, cost, usage = call_model(cfg["backend"], PROJECT_SYSTEM_PROMPT, project_prompt(meta, doc["core"], brief, themes, schema), model, schema)
        bib_key = resolve_bib_key(ck, keys_in_bib); n_cites, snippets = manuscript_uses(bib_key, cfg["manuscripts"])
        xref = {"in_bib": bib_key is not None, "bib_key": bib_key, "n_cites": n_cites, "snippets": snippets}
        m = dict(doc["_meta"]); m.update({"project_hash": h, "project_model": model, "project_cost_usd": cost, "project_usage": usage,
                                          "project_generated_at": dt.datetime.now().strftime("%Y-%m-%d")})
        row = {"citekey": ck, "year": meta["year"], "paper_type": doc["core"]["paper_type"], "one_sentence": doc["core"]["one_sentence"],
               "tags": doc["core"]["tags"], "pdf": bool(p["pdf"]), "n_cites": n_cites}
        (out / f"{ck}.md").write_text(render_md(ck, meta, doc["core"], proj, xref, m, themes), encoding="utf-8")
        (out / f"{ck}.json").write_text(json.dumps({"citekey": ck, "metadata": meta, "core": doc["core"], "project": proj, "xref": xref,
                                                    "_index": row, "_meta": m}, indent=1, ensure_ascii=False), encoding="utf-8")
        return ck, row, cost, usage
    total = 0.0
    with concurrent.futures.ThreadPoolExecutor(max_workers=int(cfg["jobs"])) as ex:
        futures = {ex.submit(work, job): citekey_for(job[0]["item"]) for job in todo}
        for fut in concurrent.futures.as_completed(futures):
            ck = futures[fut]
            try:
                ck, row, cost, usage = fut.result()
            except Exception as e:
                print(f"FAILED {ck}: {str(e)[:300]}", file=sys.stderr); continue
            rows.append(row); total += cost
            print(f"  project {ck:42s} in={tokens_in(usage)} out={usage.get('output_tokens', '?')} ${cost:.3f}", flush=True)
    (out / "INDEX.md").write_text(render_index(cfg["collection"], rows), encoding="utf-8")
    print(f"index: {out / 'INDEX.md'} ({len(rows)} papers)" + (f"; project layer this run ${total:.2f} (API-equivalent)" if todo else ""))


def refresh_xref(p, doc, existing, cfg, out, keys_in_bib, themes):
    meta = metadata(p["item"]); ck = citekey_for(p["item"])
    bib_key = resolve_bib_key(ck, keys_in_bib); n_cites, snippets = manuscript_uses(bib_key, cfg["manuscripts"])
    xref = {"in_bib": bib_key is not None, "bib_key": bib_key, "n_cites": n_cites, "snippets": snippets}
    if xref != existing.get("xref"):
        existing["xref"] = xref; existing["_index"]["n_cites"] = n_cites
        (out / f"{ck}.md").write_text(render_md(ck, meta, doc["core"], existing["project"], xref, existing["_meta"], themes), encoding="utf-8")
        (out / f"{ck}.json").write_text(json.dumps(existing, indent=1, ensure_ascii=False), encoding="utf-8")
    return existing["_index"]


# --------------------------------------------------------------------------- commands
def resolve_settings(a):
    cfg = load_config(getattr(a, "config", None) or CONFIG_NAME)
    for k in ("collection", "out", "brief", "model", "project_model", "backend", "jobs"):
        v = getattr(a, k, None)
        if v is not None:
            cfg[k] = v
    return cfg


def cmd_run(a):
    cfg = resolve_settings(a)
    if not cfg["collection"]:
        sys.exit(f"No collection given. Pass --collection or run `zotero-digest init` to create {CONFIG_NAME}.")
    col = find_collection(cfg["collection"]); cfg["collection"] = col["data"]["name"]
    out = pathlib.Path(cfg["out"] or f"literature/{slugify(col['data']['name'])}"); out.mkdir(parents=True, exist_ok=True)
    papers = papers_in(col["key"])
    print(f"{col['data']['name']}: {len(papers)} papers, {sum(1 for p in papers if p['pdf'])} with PDFs -> {out}")
    store = NoteStore()
    docs = digest_core(store, papers, cfg, a)
    project_layer(papers, docs, cfg, out, a)


def cmd_library(a):
    cfg = resolve_settings(a)
    if a.all:
        papers = papers_in(None); label = "whole library"
    else:
        name = cfg["collection"]
        if not name:
            sys.exit("Pass --collection NAME or --all.")
        col = find_collection(name); papers = papers_in(col["key"]); label = col["data"]["name"]
    print(f"{label}: {len(papers)} papers, {sum(1 for p in papers if p['pdf'])} with PDFs")
    digest_core(NoteStore(), papers, cfg, a)


def cmd_index(a):
    cfg = resolve_settings(a)
    col = find_collection(cfg["collection"])
    out = pathlib.Path(cfg["out"] or f"literature/{slugify(col['data']['name'])}")
    rows = [json.loads(f.read_text(encoding="utf-8"))["_index"] for f in sorted(out.glob("*.json"))]
    (out / "INDEX.md").write_text(render_index(col["data"]["name"], rows), encoding="utf-8")
    print(f"index: {out / 'INDEX.md'} ({len(rows)} papers)")


def cmd_migrate(a):
    """Move the core content of existing digest files (v0.1 or v0.2) into the note store without model calls,
    and convert v0.1 project files in place so their relevance sections are kept rather than regenerated."""
    cfg = resolve_settings(a)
    themes = cfg["themes"]
    model = cfg["project_model"] or cfg["model"] or (CLI_MODEL if cfg["backend"] == "cli" else API_MODEL)
    brief_path = pathlib.Path(cfg["brief"]) if cfg["brief"] else None
    brief = brief_path.read_text(encoding="utf-8") if brief_path and brief_path.exists() else ""
    brief = re.sub(r"<!--.*?-->", "", brief, flags=re.S).strip()
    store = NoteStore()
    files = sorted(pathlib.Path(a.directory).glob("*.json"))
    done = skipped = converted = 0
    for f in files:
        d = json.loads(f.read_text(encoding="utf-8"))
        src = d.get("core") or d.get("digest")
        key = (d.get("metadata") or {}).get("zotero_key")
        if not src or not key or not all(k in src for k in CORE_FIELDS):
            print(f"  skip {f.name}: not a digest file"); skipped += 1; continue
        core = {k: src[k] for k in CORE_FIELDS}
        old = d.get("_meta", {})
        meta_info = {"pdf": old.get("pdf"), "pdf_sha256": old.get("pdf_sha256"), "pdf_pages": old.get("pdf_pages"),
                     "truncated": old.get("truncated", False), "model": old.get("model"), "backend": old.get("backend"),
                     "prompt_version": old.get("prompt_version", CORE_PROMPT_VERSION), "digested_at": old.get("digested_at"),
                     "cost_usd": old.get("cost_usd", 0.0), "usage": old.get("usage", {}), "citekey": d.get("citekey"),
                     "title": d.get("metadata", {}).get("title", ""), "migrated_from": str(f)}
        existing = store.get(key)
        if existing and not a.force and existing["_meta"].get("pdf_sha256") == meta_info["pdf_sha256"]:
            doc = existing; skipped += 1
        elif a.dry_run:
            print(f"  would write note for {d.get('citekey')} ({key})"); done += 1; doc = {"core": core, "_meta": meta_info}
        else:
            doc = store.put(key, core, meta_info, meta_info["title"]); done += 1
            print(f"  note {d.get('citekey'):45s} -> {store.kind()}", flush=True)
        # v0.1 project file: keep its relevance sections by rewriting it in the v0.2 layout
        if "digest" in d and all(t["key"] in src for t in themes) and "how_to_use" in src and not a.dry_run:
            proj = {t["key"]: src[t["key"]] for t in themes}; proj["how_to_use"] = src["how_to_use"]
            m = dict(meta_info); m.update({"project_hash": project_hash(doc, brief, themes, model), "project_model": meta_info["model"],
                                           "project_generated_at": meta_info["digested_at"], "converted_from": "v0.1"})
            xref = d.get("xref", {"in_bib": False, "bib_key": None, "n_cites": 0, "snippets": []})
            row = d.get("_index") or {"citekey": d["citekey"], "year": d["metadata"]["year"], "paper_type": core["paper_type"],
                                      "one_sentence": core["one_sentence"], "tags": core["tags"], "pdf": bool(meta_info["pdf"]),
                                      "n_cites": xref.get("n_cites", 0)}
            f.write_text(json.dumps({"citekey": d["citekey"], "metadata": d["metadata"], "core": core, "project": proj, "xref": xref,
                                     "_index": row, "_meta": m}, indent=1, ensure_ascii=False), encoding="utf-8")
            f.with_suffix(".md").write_text(render_md(d["citekey"], d["metadata"], core, proj, xref, m, themes), encoding="utf-8")
            converted += 1
    print(f"migrated {done}, skipped {skipped} ({store.kind()} store); converted {converted} project file(s) to v0.2 layout")


def main():
    ap = argparse.ArgumentParser(prog="zotero-digest", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version=f"zotero-digest {__version__}")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("collections", help="list Zotero collections"); s.set_defaults(fn=cmd_collections)
    s = sub.add_parser("auth", help="check ZOTERO_API_KEY and show the library id"); s.set_defaults(fn=cmd_auth)
    s = sub.add_parser("init", help=f"write {CONFIG_NAME}, a brief template, and a .gitignore line")
    s.add_argument("--collection"); s.add_argument("--out"); s.add_argument("--config"); s.add_argument("--force", action="store_true")
    s.set_defaults(fn=cmd_init)

    def common(s, with_run_flags=True):
        s.add_argument("--config", help=f"config file (default ./{CONFIG_NAME})")
        s.add_argument("--collection"); s.add_argument("--out"); s.add_argument("--brief")
        s.add_argument("--backend", choices=["cli", "api"]); s.add_argument("--model"); s.add_argument("--project-model", dest="project_model")
        s.add_argument("--jobs", type=int)
        if with_run_flags:
            s.add_argument("--limit", type=int); s.add_argument("--only", nargs="*")
            s.add_argument("--force", action="store_true"); s.add_argument("--dry-run", action="store_true")

    s = sub.add_parser("run", help="core layer (in Zotero) + project layer (files) for the project's collection"); common(s); s.set_defaults(fn=cmd_run)
    s = sub.add_parser("library", help="core layer only, for a collection or the whole library"); common(s)
    s.add_argument("--all", action="store_true", help="every item in the library"); s.set_defaults(fn=cmd_library)
    s = sub.add_parser("index", help="rebuild INDEX.md from existing project files"); common(s, with_run_flags=False); s.set_defaults(fn=cmd_index)
    s = sub.add_parser("text", help="page-aware text of one paper: outline, a section, a page range, or grep hits")
    s.add_argument("ref", help="citation key, Zotero item key, or DOI")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--outline", action="store_true", help="detected sections with pdf pages and sizes (default)")
    g.add_argument("--section", help="print the section whose heading contains this text, e.g. results")
    g.add_argument("--pages", help="print pdf pages N or N-M")
    g.add_argument("--grep", help="regex; print matching lines with pdf page numbers")
    s.add_argument("--context", type=int, default=1, help="lines of context around grep hits (default 1)")
    s.add_argument("--max-chars", type=int, default=40000, help="cap on printed characters (default 40000, ~10k tokens)")
    s.set_defaults(fn=cmd_text)
    s = sub.add_parser("find", help="search all stored core digests (no model call)")
    s.add_argument("query"); s.add_argument("--limit", type=int, default=10)
    s.add_argument("--all-terms", action="store_true", help="require every query word to appear")
    s.set_defaults(fn=cmd_find)
    s = sub.add_parser("bib", help="BibTeX from Zotero (Better BibTeX keys) for given keys or the project's collection")
    s.add_argument("refs", nargs="*", help="citation keys, item keys, or DOIs; none = the project's collection")
    s.add_argument("--config"); s.add_argument("--collection")
    s.add_argument("--append-to", help="append entries to this .bib instead of printing")
    s.add_argument("--missing-only", action="store_true", help="only entries whose key is not yet in the project's .bib")
    s.set_defaults(fn=cmd_bib)
    s = sub.add_parser("check", help="lint: every key cited in the manuscript(s) must exist in the .bib")
    s.add_argument("files", nargs="*", help="manuscript files (default: the config's manuscripts globs)")
    s.add_argument("--config"); s.add_argument("--unused", action="store_true", help="also list bib entries never cited")
    s.set_defaults(fn=cmd_check)
    s = sub.add_parser("migrate", help="turn existing digest files into notes without model calls")
    s.add_argument("directory"); s.add_argument("--force", action="store_true"); s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_migrate)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()

# -*- coding: utf-8 -*-
"""
SWInv — генератор JSON-воркфлоу для n8n 2.37 (D:\\bank-test\\n8n\\workflows\\*.json).
Чому генератор, а не ручний JSON: Code-ноди містять JS з лапками/бекслешами — json.dump
гарантує коректне екранування; координати нод рахуються автоматично; спільний код
(normalize.js) вставляється з одного джерела.
Запуск: python n8n/build_workflows.py
"""
import json, os, re, io

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'workflows')
os.makedirs(OUT, exist_ok=True)

CRED_PG = {"postgres": {"id": "swinvPostgres01", "name": "SWInv Postgres (inventory)"}}
CRED_OLLAMA = {"ollamaApi": {"id": "swinvOllama0001", "name": "SWInv Ollama (local GPU)"}}
CRED_HEADER = {"httpHeaderAuth": {"id": "swinvWebhookTok", "name": "SWInv Collector Token (header X-Inventory-Token)"}}

WF_INGEST_ID = 'swinvIngest00001'
WF_REVIEW_ID = 'swinvReview00001'
WF_DASH_ID = 'swinvDashbrd0001'
WF_ERROR_ID = 'swinvErrors00001'

PROMPT_VERSION = 'p1'
BATCH_SIZE = 10
CATEGORY_CODES = ['OS_COMPONENT', 'RUNTIME', 'DRIVER', 'DEV_TOOLS', 'DATABASE', 'VIRTUALIZATION', 'OFFICE', 'BROWSER',
                  'COMMUNICATION', 'SECURITY', 'SYSTEM_UTILITY', 'MEDIA', 'REMOTE_ACCESS', 'CLOUD_STORAGE',
                  'AI_ASSISTANT', 'GAMES', 'OTHER', 'UNKNOWN']

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
_node_counter = [0]


def nid():
    _node_counter[0] += 1
    return 'n%03d' % _node_counter[0]


def node(name, type_, version, params, x, y, **extra):
    n = {"parameters": params, "id": nid(), "name": name, "type": type_, "typeVersion": version, "position": [x, y]}
    n.update(extra)
    return n


def sticky(content, x, y, w=420, h=120, color=1):
    return node('Note ' + nid(), 'n8n-nodes-base.stickyNote', 1, {"content": content, "height": h, "width": w, "color": color}, x, y)


def pg(name, query, params_expr, x, y, **extra):
    p = {"operation": "executeQuery", "query": query, "options": {}}
    if params_expr:
        p["options"]["queryReplacement"] = params_expr
    return node(name, 'n8n-nodes-base.postgres', 2.7, p, x, y, credentials=CRED_PG, **extra)


def code(name, js, x, y, each=False, **extra):
    p = {"jsCode": js}
    if each:
        p["mode"] = "runOnceForEachItem"
    return node(name, 'n8n-nodes-base.code', 2, p, x, y, **extra)


def connect(conns, src, dst, out_index=0, in_index=0, type_='main'):
    conns.setdefault(src, {}).setdefault(type_, [])
    lst = conns[src][type_]
    while len(lst) <= out_index:
        lst.append([])
    lst[out_index].append({"node": dst, "type": type_, "index": in_index})


def workflow(wid, name, nodes, conns, settings=None, tags=None):
    s = {"executionOrder": "v1", "saveManualExecutions": True, "saveExecutionProgress": True}
    if settings:
        s.update(settings)
    return {"id": wid, "name": name, "nodes": nodes, "connections": conns, "settings": s, "active": False,
            "meta": {"templateCredsSetupCompleted": True}}


def read(path):
    with io.open(path, 'r', encoding='utf-8') as f:
        return f.read()


NORMALIZE_JS = read(os.path.join(HERE, 'code', 'normalize.js'))
# convert the module into an inline snippet usable in a Code node
NORMALIZE_INLINE = NORMALIZE_JS.split('module.exports')[0]

# ---------------------------------------------------------------------------
# Workflow 1: Ingest & Classify
# ---------------------------------------------------------------------------

JS_VALIDATE = r"""
// Валідація payload колектора (контракт docs/CONTRACT-collector.md)
const body = $input.first().json.body || {};
const errors = [];
if (body.schema_version !== '1.0') errors.push('schema_version має бути "1.0"');
if (!body.host || !body.host.machine_id || !body.host.hostname) errors.push('host.machine_id / host.hostname відсутні');
if (!Array.isArray(body.packages) || body.packages.length === 0) errors.push('packages порожній');
if (!body.run_id) errors.push('run_id відсутній');
if (errors.length) throw new Error('Некоректний payload: ' + errors.join('; '));
const required = ['source', 'source_key', 'name'];
const bad = body.packages.filter(p => required.some(k => !p[k]));
if (bad.length) throw new Error(`У ${bad.length} пакетів відсутні обов'язкові поля (source, source_key, name)`);
const bySource = {};
for (const p of body.packages) bySource[p.source] = (bySource[p.source] || 0) + 1;
return [{ json: {
  host: body.host,
  run: { run_id: body.run_id, collected_at: body.collected_at, collector_version: (body.collector || {}).version || null,
         sources: body.sources || [], packages_total: body.packages.length },
  packages: body.packages,
  summary: { packages: body.packages.length, by_source: bySource }
}}];
"""

JS_NORMALIZE = NORMALIZE_INLINE + r"""
// ---- застосування до payload ----
const input = $input.first().json;
const packages = input.packages.map(normalizePackage);
const fps = new Set(packages.map(p => p.fingerprint));
return [{ json: { host: input.host, run: input.run, packages,
  summary: Object.assign({}, input.summary, { fingerprints: fps.size, norm_version: NORM_VERSION }) } }];
"""

JS_BATCH = r"""
// Невідомі відбитки -> батчі фіксованого розміру, відсортовані (детермінований порядок промптів)
const rows = $input.all().map(i => i.json).filter(r => r && r.fingerprint);
rows.sort((a, b) => a.fingerprint < b.fingerprint ? -1 : a.fingerprint > b.fingerprint ? 1 : 0);
const SIZE = %(batch)d;
const out = [];
for (let i = 0; i < rows.length; i += SIZE) {
  const chunk = rows.slice(i, i + SIZE).map((r, k) => ({ id: k + 1, fingerprint: r.fingerprint, name: r.name, name_clean: r.name_clean,
    publisher: r.publisher, source: r.source, version: r.version, winget_id: r.winget_id,
    is_system_component: !!r.is_system_component, install_location: r.install_location, occurrences: r.occurrences }));
  out.push({ json: { batch_no: out.length + 1, total_batches: Math.ceil(rows.length / SIZE), size: chunk.length, items: chunk } });
}
return out;
""" % {"batch": BATCH_SIZE}

JS_PROMPT = r"""
// Формування промпту (prompt_version = %(pv)s). Таксономія береться з довідника dict_category (закритий перелік).
const batch = $input.first().json;
const cats = ($('Довідник категорій').first().json.categories) || [];
const model = $env.OLLAMA_MODEL || 'qwen2.5:14b';
const catLines = cats.map(c => `- ${c.code} — ${c.name_uk} (${c.name_en}): ${c.description || ''}`).join('\n');
const system = [
  'You are a software asset management (SAM) analyst at a bank. You receive a numbered list of software PACKAGES detected on a Windows PC',
  '(registry Uninstall entries, MSIX/Appx packages, winget rows, npm/pip packages, VS Code extensions).',
  'For EACH input package return one object with fields:',
  '- id: the same integer id as in the input (echo back; every input id exactly once)',
  '- software: canonical PRODUCT name the package belongs to. No version numbers, no architecture (x64/x86), no locale suffixes.',
  '  Keep a year only when it is part of the product name (e.g. "Microsoft SQL Server 2025"). Sub-components map to the PARENT product',
  '  (e.g. "SQL Server 2025 Database Engine Shared" -> "Microsoft SQL Server 2025"; "ENE_MousePad_HAL" -> "ENE Device HAL Drivers").',
  '- vendor: canonical vendor name without legal suffixes (Inc., LLC, Ltd, s.r.o., Corporation). Use Latin script for well-known vendors.',
  '- category: exactly ONE code from the closed list below. If you truly cannot decide, use UNKNOWN. Never invent codes.',
  '- is_component: true if the package is a sub-component / runtime piece / HAL / helper of a larger product, false if it IS the product.',
  '- confidence: number 0.0-1.0 for software+category together.',
  '- reason: short justification in Ukrainian, max 12 words.',
  '',
  'Closed category list (code — Ukrainian name (English name): what belongs):',
  catLines,
  '',
  'Guidance: games, game launchers, game mods, emulators for games and gaming overlays are GAMES; VPN, tunnels and remote desktop tools are REMOTE_ACCESS;',
  'hardware vendor utilities, HAL, firmware, capture-box and RGB/peripheral tools are DRIVER; Windows inbox apps, system MSIX packages and GUID-named Microsoft',
  'system packages are OS_COMPONENT; frameworks, redistributables, SDK runtimes (Vulkan, PlayStation PC SDK Runtime, WinAppRuntime) are RUNTIME;',
  'torrent clients, screenshot tools, virtual drives are SYSTEM_UTILITY; note-taking, whiteboard, design (Figma) and writing assistants (Grammarly) are OFFICE;',
  'Android emulators (LDPlayer, BlueStacks) are VIRTUALIZATION; cloud CLIs (Google Cloud SDK, twilio-cli, ngrok) and debuggers are DEV_TOOLS.',
  'Software from a piracy/torrent site publisher: classify by what the software is (a game -> GAMES) and mention the source in reason.',
  '',
  'Examples (input -> software | vendor | category | is_component | confidence):',
  '- "Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.38.33135" | Microsoft Corporation -> Microsoft Visual C++ Redistributable | Microsoft | RUNTIME | false | 0.98',
  '- "SQL Server 2025 Database Engine Shared" | Microsoft Corporation -> Microsoft SQL Server 2025 | Microsoft | DATABASE | true | 0.97',
  '- "TunnelBear" | TunnelBear -> TunnelBear | TunnelBear | REMOTE_ACCESS | false | 0.95',
  '- "Warcraft III" | Blizzard Entertainment -> Warcraft III | Blizzard Entertainment | GAMES | false | 0.97',
  '- "Термінал Windows" | Microsoft -> Windows Terminal | Microsoft | DEV_TOOLS | false | 0.95',
  '- "1527c705-839a-4832-9118-54d4Bd6a0c89" | Microsoft Corporation (appx, system) -> Windows System Package | Microsoft | OS_COMPONENT | true | 0.7',
  '',
  'Return ONLY a JSON object of the form: items = array of objects with the fields above. No prose.'
].join('\n');
const lines = batch.items.map(it => {
  const parts = [`name="${it.name}"`, `publisher="${it.publisher || ''}"`, `source=${it.source}`];
  if (it.version) parts.push(`version=${it.version}`);
  if (it.winget_id) parts.push(`winget_id=${it.winget_id}`);
  if (it.is_system_component) parts.push('system_component=true');
  if (it.install_location) parts.push(`location="${String(it.install_location).split(/[\\/]/).slice(-2).join('/')}"`);
  return `${it.id}. ${parts.join(' | ')}`;
});
const prompt = `Classify these ${batch.items.length} packages (batch ${batch.batch_no}/${batch.total_batches}). Return one object with key "items" and exactly ${batch.items.length} entries (ids 1..${batch.items.length}).\n` + lines.join('\n');
return [{ json: Object.assign({}, batch, { system_prompt: system, prompt, model, prompt_version: '%(pv)s' }) }];
""" % {"pv": PROMPT_VERSION}

JS_VALIDATE_AI = r"""
// Детермінована валідація відповіді AI: echo-back id, закритий перелік категорій, пороги впевненості.
// Нічого не потрапляє в довідник, поки не пройде цю перевірку.
const batch = $('Промпт для AI').first().json;
const cats = new Set((($('Довідник категорій').first().json.categories) || []).map(c => c.code));
const raw = $input.first().json;
let out = raw.output;
if (typeof out === 'string') { try { out = JSON.parse(out); } catch (e) { out = null; } }
let items = out && (Array.isArray(out) ? out : (out.items || (out.output && out.output.items)));
if (!Array.isArray(items)) {
  return [{ json: { ok: false, reason: 'invalid_output', error: 'AI не повернув масив items', batch_no: batch.batch_no } }];
}
const ACCEPT = 0.80, ACCEPT_REVIEW = 0.60;
const byId = new Map(batch.items.map(it => [it.id, it]));
const seen = new Set(); const results = []; const stats = { accept: 0, accept_review: 0, review: 0, invalid: 0 };
for (const r of items) {
  const id = Number(r.id); const src = byId.get(id);
  if (!src || seen.has(id)) { stats.invalid++; continue; }
  seen.add(id);
  let cat = String(r.category || '').toUpperCase().trim();
  let conf = Number(r.confidence); if (!isFinite(conf)) conf = 0; conf = Math.max(0, Math.min(1, conf));
  const software = String(r.software || '').trim().slice(0, 200);
  const vendor = String(r.vendor || '').trim().slice(0, 120);
  let decision, review_reason = null;
  if (!cats.has(cat)) { decision = 'review'; review_reason = 'unknown_category'; cat = null; }
  else if (cat === 'OTHER') { decision = 'review'; review_reason = 'low_confidence'; }
  else if (!software) { decision = 'review'; review_reason = 'invalid_output'; }
  else if (conf >= ACCEPT) decision = 'accept';
  else if (conf >= ACCEPT_REVIEW) { decision = 'accept_review'; review_reason = 'low_confidence'; }
  else { decision = 'review'; review_reason = 'low_confidence'; }
  stats[decision]++;
  results.push({ fingerprint: src.fingerprint, decision, software_name: software || null, vendor_name: vendor || null,
    category_code: cat, is_component: !!r.is_component, confidence: Number(conf.toFixed(3)), reason: String(r.reason || '').slice(0, 200),
    review_reason, sample_name: src.name, sample_publisher: src.publisher || null, sample_source: src.source, sample_version: src.version || null });
}
for (const it of batch.items) {
  if (seen.has(it.id)) continue;
  stats.review++;
  results.push({ fingerprint: it.fingerprint, decision: 'review', software_name: null, vendor_name: null, category_code: null, is_component: false,
    confidence: 0, reason: 'AI не повернув відповідь для цього пакета', review_reason: 'invalid_output',
    sample_name: it.name, sample_publisher: it.publisher || null, sample_source: it.source, sample_version: it.version || null });
}
if (seen.size < Math.ceil(batch.items.length / 2)) {
  return [{ json: { ok: false, reason: 'invalid_output', error: `echo-back провалено: ${seen.size} з ${batch.items.length} id`, batch_no: batch.batch_no } }];
}
return [{ json: { ok: true, batch_no: batch.batch_no, model: batch.model, prompt_version: batch.prompt_version, stats, results } }];
"""

OUTPUT_SCHEMA = {
    "type": "object",
    "properties": {
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "integer"},
                    "software": {"type": "string"},
                    "vendor": {"type": "string"},
                    "category": {"type": "string", "enum": CATEGORY_CODES},
                    "is_component": {"type": "boolean"},
                    "confidence": {"type": "number"},
                    "reason": {"type": "string"}
                },
                "required": ["id", "software", "vendor", "category", "is_component", "confidence"]
            }
        }
    },
    "required": ["items"]
}


def build_ingest():
    _node_counter[0] = 0
    nodes = []
    conns = {}
    Y = 400
    # --- lane 1: приймання
    n_webhook = node('Webhook: POST /inventory/ingest', 'n8n-nodes-base.webhook', 2.1,
                     {"httpMethod": "POST", "path": "inventory/ingest", "authentication": "headerAuth",
                      "responseMode": "responseNode", "options": {"rawBody": False}},
                     0, Y, webhookId="swinv-inventory-ingest-0001", credentials=CRED_HEADER)
    n_validate = code('Валідація payload', JS_VALIDATE, 240, Y)
    n_norm = code('Нормалізація (norm_v1)', JS_NORMALIZE, 480, Y)
    n_host = pg('БД: хост + запуск', "SELECT * FROM swinv_upsert_host_run($1::jsonb, $2::jsonb)",
                "={{ [ JSON.stringify($json.host), JSON.stringify($json.run) ] }}", 720, Y)
    n_ingest = pg('БД: пакети + diff (jsonb, set-based)',
                  "SELECT swinv_ingest_packages($1::int, $2::uuid, $3::jsonb) AS result",
                  "={{ [ $json.host_id, $json.run_id, JSON.stringify($('Нормалізація (norm_v1)').first().json.packages) ] }}", 960, Y)
    n_respond = node('Відповідь колектору (202 Accepted)', 'n8n-nodes-base.respondToWebhook', 1.5,
                     {"respondWith": "json",
                      "responseBody": "={{ JSON.stringify({ accepted: true, run_id: $('БД: хост + запуск').first().json.run_id, host_id: $('БД: хост + запуск').first().json.host_id, diff: $json.result, note: 'класифікація виконується асинхронно; дашборд: /webhook/inventory/dashboard' }) }}",
                      "options": {"responseCode": 202, "responseHeaders": {"entries": [{"name": "Content-Type", "value": "application/json; charset=utf-8"}]}}},
                     1200, Y)
    # --- lane 2: детерміноване зіставлення
    n_exact = pg('БД: крок 1 — точні збіги (довідник)', "SELECT swinv_match_exact($1::int, $2::uuid) AS result",
                 "={{ [ $('БД: хост + запуск').first().json.host_id, $('БД: хост + запуск').first().json.run_id ] }}", 1440, Y)
    n_rules = pg('БД: крок 2 — правила (dict_rules)', "SELECT swinv_apply_rules($1::int, $2::uuid) AS result",
                 "={{ [ $('БД: хост + запуск').first().json.host_id, $('БД: хост + запуск').first().json.run_id ] }}", 1680, Y)
    n_cats = pg('Довідник категорій',
                "SELECT jsonb_agg(jsonb_build_object('code', code, 'name_uk', name_uk, 'name_en', name_en, 'description', description, 'policy', policy) ORDER BY sort_order) AS categories FROM dict_category",
                None, 1920, Y)
    n_unres = pg('БД: крок 3 — невідомі (для AI)', "SELECT * FROM swinv_unresolved($1::int) ORDER BY fingerprint",
                 "={{ [ $('БД: хост + запуск').first().json.host_id ] }}", 2160, Y, alwaysOutputData=True, executeOnce=True)
    n_if = node('Є невідомі пакети?', 'n8n-nodes-base.if', 2.3,
                {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
                                "conditions": [{"id": "c-unres", "leftValue": "={{ $json.fingerprint }}", "rightValue": "",
                                                "operator": {"type": "string", "operation": "exists", "singleValue": True}}],
                                "combinator": "and"}, "looseTypeValidation": True, "options": {}}, 2400, Y)
    # --- lane 3: AI
    YA = Y - 260
    n_batch = code('Пакетування (по %d, відсортовано)' % BATCH_SIZE, JS_BATCH, 2640, YA)
    n_loop = node('Цикл по батчах', 'n8n-nodes-base.splitInBatches', 3, {"batchSize": 1, "options": {}}, 2880, YA)
    n_prompt = code('Промпт для AI', JS_PROMPT, 3120, YA - 200)
    n_chain = node('AI: класифікація (Basic LLM Chain)', '@n8n/n8n-nodes-langchain.chainLlm', 1.9,
                   {"promptType": "define", "text": "={{ $json.prompt }}", "hasOutputParser": True,
                    "messages": {"messageValues": [{"type": "SystemMessagePromptTemplate", "message": "={{ $json.system_prompt }}"}]},
                    "batching": {}},
                   3360, YA - 200, onError="continueErrorOutput", retryOnFail=True, maxTries=2, waitBetweenTries=3000)
    n_ollama = node('Ollama Chat Model (локально, GPU)', '@n8n/n8n-nodes-langchain.lmChatOllama', 1,
                    {"model": "={{ $env.OLLAMA_MODEL || 'qwen2.5:14b' }}",
                     "options": {"temperature": 0, "format": "json", "numCtx": 8192, "numPredict": 2048, "keepAlive": "24h", "topK": 1}},
                    3300, YA + 40, credentials=CRED_OLLAMA)
    n_parser = node('Структурований вивід (JSON Schema)', '@n8n/n8n-nodes-langchain.outputParserStructured', 1.3,
                    {"schemaType": "manual", "inputSchema": json.dumps(OUTPUT_SCHEMA, ensure_ascii=False, indent=2), "autoFix": False},
                    3520, YA + 40)
    n_openai = node('OpenAI Chat Model (альтернатива, вимкнено)', '@n8n/n8n-nodes-langchain.lmChatOpenAi', 1.3,
                    {"model": {"__rl": True, "mode": "list", "value": "gpt-4o-mini"}, "options": {"temperature": 0}},
                    3300, YA + 220, disabled=True)
    n_valid = code('Валідація відповіді AI', JS_VALIDATE_AI, 3760, YA - 200)
    n_if_ok = node('Відповідь валідна?', 'n8n-nodes-base.if', 2.3,
                   {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
                                   "conditions": [{"id": "c-ok", "leftValue": "={{ $json.ok }}", "rightValue": True,
                                                   "operator": {"type": "boolean", "operation": "true", "singleValue": True}}],
                                   "combinator": "and"}, "looseTypeValidation": True, "options": {}}, 4000, YA - 200)
    n_apply = pg('БД: запис результатів AI (пріоритет ai=100)',
                 "SELECT swinv_apply_ai_results($1::uuid, $2::int, $3::text, $4::text, $5::jsonb) AS result",
                 "={{ [ $('БД: хост + запуск').first().json.run_id, $('БД: хост + запуск').first().json.host_id, $json.model, $json.prompt_version, JSON.stringify($json.results) ] }}",
                 4260, YA - 300)
    n_failed = pg('БД: батч у чергу перевірки (AI недоступний / невалідно)',
                  "SELECT swinv_ai_failed($1::uuid, $2::int, $3::jsonb, $4::text, $5::text) AS result",
                  "={{ [ $('БД: хост + запуск').first().json.run_id, $('БД: хост + запуск').first().json.host_id, JSON.stringify($('Промпт для AI').first().json.items.map(i => ({ fingerprint: i.fingerprint, name: i.name, publisher: i.publisher, source: i.source, version: i.version }))), ($json.ok === false ? $json.reason : 'ai_unavailable'), String(($json.error && $json.error.message) || $json.error || $json.message || 'LLM error').slice(0, 500) ] }}",
                  4260, YA - 60)
    # --- lane 4: фіналізація
    n_final = pg('БД: фіналізація запуску (лічильники)', "SELECT swinv_finalize_run($1::uuid) AS result",
                 "={{ [ $('БД: хост + запуск').first().json.run_id ] }}", 3120, Y + 120, executeOnce=True)
    n_summary = code('Підсумок запуску', r"""
const r = $input.first().json.result || {};
const line = `Запуск ${r.run_id}: пакетів ${r.packages_total} (нових ${r.added}, змінених ${r.changed}, видалених ${r.removed}); ` +
  `відбитків ${r.fingerprints_total}, відомі до запуску ${r.known_before}, закрито правилами ${r.resolved_rule}, точно ${r.resolved_exact}, ` +
  `AI ${r.resolved_ai} (звернень до AI: ${r.ai_calls}), без продукту ${r.unresolved}, змін довідників ${r.dict_changes}, ${r.duration_ms} мс`;
return [{ json: Object.assign({ summary: line }, r) }];
""", 3360, Y + 120)

    for n in [n_webhook, n_validate, n_norm, n_host, n_ingest, n_respond, n_exact, n_rules, n_cats, n_unres, n_if,
              n_batch, n_loop, n_prompt, n_chain, n_ollama, n_parser, n_openai, n_valid, n_if_ok, n_apply, n_failed, n_final, n_summary]:
        nodes.append(n)

    # sticky notes (lanes)
    nodes.append(sticky("## 1 · Приймання та нормалізація\nКолектор (PowerShell) надсилає JSON зі всіма пакетами ПК. Валідація контракту → **norm_v1**: один відбиток для пакета незалежно від версії, розрядності, локалі. Set-based upsert у Postgres (jsonb_to_recordset) + diff added/changed/removed. Колектор отримує відповідь одразу, класифікація йде асинхронно.", -40, Y - 220, 1200, 150, 4))
    nodes.append(sticky("## 2 · Детерміноване зіставлення — БЕЗ AI\nКрок 1: відбиток уже в довіднику → продукт відомий, AI не викликається. Крок 2: **правила як дані** (dict_rules, regex у Postgres). Тільки те, що залишилось, іде на крок 3.\nПовторний запуск на тому ж ПК → 0 звернень до AI, 0 змін довідників.", 1400, Y - 220, 1200, 150, 4))
    nodes.append(sticky("## 3 · AI лише для невідомого\nБатчі по %d, відсортовані (детермінований промпт). Таксономія — закритий перелік з dict_category. temperature 0, JSON Schema, echo-back id, пороги впевненості (≥0.80 прийняти, 0.60–0.80 прийняти + на перевірку, <0.60 лише перевірка).\n**Модель — локальна (Ollama на GPU): дані не залишають периметр.** Заміна на OpenAI = одна нода поруч." % BATCH_SIZE, 2600, YA - 460, 1300, 190, 5))
    nodes.append(sticky("## 4 · Запис у довідники з пріоритетами\ndict_package_map: human(400) > seed(350) > rule(300) > exact(200) > ai(100). `ON CONFLICT … WHERE EXCLUDED.priority >= priority` — AI ніколи не перезапише рішення людини. Кожна зміна довідника → audit_log (тригер БД).", 4200, YA - 460, 620, 190, 6))
    nodes.append(sticky("## 5 · Фіналізація\nЛічильники запуску (inventory_runs): відомі/правила/AI/нерозв'язані, звернення до AI, зміни довідників. Це числовий доказ прогнозованості на дашборді.", 3080, Y + 260, 640, 120, 7))

    # connections
    c = conns
    connect(c, n_webhook['name'], n_validate['name'])
    connect(c, n_validate['name'], n_norm['name'])
    connect(c, n_norm['name'], n_host['name'])
    connect(c, n_host['name'], n_ingest['name'])
    connect(c, n_ingest['name'], n_respond['name'])
    connect(c, n_respond['name'], n_exact['name'])
    connect(c, n_exact['name'], n_rules['name'])
    connect(c, n_rules['name'], n_cats['name'])
    connect(c, n_cats['name'], n_unres['name'])
    connect(c, n_unres['name'], n_if['name'])
    connect(c, n_if['name'], n_batch['name'], 0)          # true
    connect(c, n_if['name'], n_final['name'], 1)          # false
    connect(c, n_batch['name'], n_loop['name'])
    connect(c, n_loop['name'], n_final['name'], 0)        # done
    connect(c, n_loop['name'], n_prompt['name'], 1)       # loop
    connect(c, n_prompt['name'], n_chain['name'])
    connect(c, n_ollama['name'], n_chain['name'], type_='ai_languageModel')
    connect(c, n_parser['name'], n_chain['name'], type_='ai_outputParser')
    connect(c, n_chain['name'], n_valid['name'], 0)       # success
    connect(c, n_chain['name'], n_failed['name'], 1)      # error output
    connect(c, n_valid['name'], n_if_ok['name'])
    connect(c, n_if_ok['name'], n_apply['name'], 0)
    connect(c, n_if_ok['name'], n_failed['name'], 1)
    connect(c, n_apply['name'], n_loop['name'])
    connect(c, n_failed['name'], n_loop['name'])
    connect(c, n_final['name'], n_summary['name'])

    return workflow(WF_INGEST_ID, 'SWInv · 1. Інвентаризація та класифікація', nodes, conns,
                    settings={"errorWorkflow": WF_ERROR_ID, "executionTimeout": 1800})


# ---------------------------------------------------------------------------
# Workflow 2: Review form (human-in-the-loop)
# ---------------------------------------------------------------------------
JS_BUILD_FORM = r"""
// Динамічна форма: категорії з довідника (закритий перелік), пропозиція AI як значення за замовчуванням
const q = $input.first().json;
const cats = q.categories || [];
const catOptions = cats.map(c => ({ option: `${c.code} — ${c.name_uk}` }));
const proposedCat = cats.find(c => c.code === q.proposed_category);
const reasonUk = { low_confidence: 'низька впевненість AI', unknown_category: 'категорія поза переліком', invalid_output: 'некоректна відповідь AI', ai_unavailable: 'AI був недоступний', manual: 'ручне' }[q.reason] || q.reason;
const html = `
<div style="font-family:system-ui;line-height:1.5">
  <p><b>Пакет:</b> ${q.sample_name || ''}<br>
  <b>Видавець:</b> ${q.sample_publisher || '—'} &nbsp; <b>Джерело:</b> ${q.sample_source || ''} &nbsp; <b>Версія:</b> ${q.sample_version || '—'}<br>
  <b>Відбиток:</b> <code>${q.fingerprint}</code></p>
  <p><b>Пропозиція AI:</b> ${q.proposed_software || '—'} / ${q.proposed_vendor || '—'} / ${q.proposed_category || '—'}
  (впевненість ${q.confidence != null ? Number(q.confidence).toFixed(2) : '—'}) — <i>${q.ai_reason || ''}</i><br>
  <b>Причина перевірки:</b> ${reasonUk} &nbsp; <b>Запис №${q.id}</b>, відкритих у черзі: ${q.open_total}</p>
</div>`;
const form = [
  { fieldLabel: 'Деталі', fieldType: 'html', elementName: 'details', html },
  { fieldLabel: 'Назва продукту', fieldType: 'text', placeholder: 'Канонічна назва без версії', defaultValue: q.proposed_software || q.sample_name || '', requiredField: true },
  { fieldLabel: 'Вендор', fieldType: 'text', placeholder: 'Без Inc./LLC/s.r.o.', defaultValue: q.proposed_vendor || q.sample_publisher || '', requiredField: false },
  { fieldLabel: 'Категорія', fieldType: 'dropdown', fieldOptions: { values: catOptions }, defaultValue: proposedCat ? `${proposedCat.code} — ${proposedCat.name_uk}` : '', requiredField: true },
  { fieldLabel: 'Це складова іншого продукту?', fieldType: 'dropdown', fieldOptions: { values: [{ option: 'Ні' }, { option: 'Так' }] }, defaultValue: q.proposed_is_component ? 'Так' : 'Ні', requiredField: true },
  { fieldLabel: 'Створити правило точного збігу (AI більше не питатимуть)', fieldType: 'dropdown', fieldOptions: { values: [{ option: 'Так' }, { option: 'Ні' }] }, defaultValue: 'Так', requiredField: true },
];
return [{ json: { form, review_id: q.id } }];
"""

JS_PARSE_DECISION = r"""
// Розбір відповіді форми -> параметри для swinv_apply_human_decision
const a = $input.first().json;
const q = $('БД: взяти запис із черги').first().json;
const catRaw = String(a['Категорія'] || '');
const category = catRaw.split(' — ')[0].trim();
return [{ json: {
  review_id: q.id,
  software_name: String(a['Назва продукту'] || '').trim(),
  vendor_name: String(a['Вендор'] || '').trim() || null,
  category_code: category,
  is_component: String(a['Це складова іншого продукту?'] || 'Ні') === 'Так',
  create_rule: String(a['Створити правило точного збігу (AI більше не питатимуть)'] || 'Так') === 'Так',
  actor: 'reviewer@n8n-form'
} }];
"""


def build_review():
    _node_counter[0] = 0
    nodes = []
    conns = {}
    Y = 300
    n_trigger = node('Форма: почати перевірку', 'n8n-nodes-base.formTrigger', 2.6,
                     {"formTitle": "SWInv · Перевірка класифікації ПЗ",
                      "formDescription": "Черга записів, де AI не був упевнений. Ваше рішення має найвищий пріоритет (human = 400) і записується в довідники з аудитом.",
                      "formFields": {"values": [
                          {"fieldLabel": "ID запису з черги (порожньо — наступний)", "fieldType": "number", "requiredField": False}
                      ]},
                      "options": {"path": "inventory/review", "buttonLabel": "Відкрити запис"}},
                     0, Y, webhookId="swinv-inventory-review-0001")
    n_take = pg('БД: взяти запис із черги',
                "SELECT q.*, (SELECT count(*) FROM review_queue WHERE status = 'open') AS open_total, "
                "(SELECT jsonb_agg(jsonb_build_object('code', code, 'name_uk', name_uk, 'policy', policy) ORDER BY sort_order) FROM dict_category) AS categories "
                "FROM review_queue q WHERE q.status = 'open' AND ($1::int IS NULL OR q.id = $1::int) ORDER BY q.created_at, q.id LIMIT 1",
                "={{ [ ($json['ID запису з черги (порожньо — наступний)'] ? Number($json['ID запису з черги (порожньо — наступний)']) : null) ] }}",
                260, Y, alwaysOutputData=True)
    n_if = node('Черга порожня?', 'n8n-nodes-base.if', 2.3,
                {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
                                "conditions": [{"id": "c-empty", "leftValue": "={{ $json.id }}", "rightValue": "",
                                                "operator": {"type": "number", "operation": "notExists", "singleValue": True}}],
                                "combinator": "and"}, "looseTypeValidation": True, "options": {}}, 520, Y)
    n_empty = node('Форма: черга порожня', 'n8n-nodes-base.form', 2.5,
                   {"operation": "completion", "respondWith": "text", "completionTitle": "Черга перевірки порожня 🎉",
                    "completionMessage": "Усі рішення AI підтверджені або перекриті людиною. Довідники в консистентному стані.", "options": {}},
                   780, Y - 160, webhookId="swinv-review-empty-0001")
    n_build = code('Побудова форми (категорії з довідника)', JS_BUILD_FORM, 780, Y + 60)
    n_page = node('Форма: рішення рецензента', 'n8n-nodes-base.form', 2.5,
                  {"operation": "page", "defineForm": "json", "jsonOutput": "={{ JSON.stringify($json.form) }}",
                   "options": {"formTitle": "Рішення рецензента", "buttonLabel": "Зберегти в довідник"}},
                  1040, Y + 60, webhookId="swinv-review-page-0001")
    n_parse = code('Розбір рішення', JS_PARSE_DECISION, 1300, Y + 60)
    n_apply = pg('БД: застосувати рішення (human=400 + правило + аудит)',
                 "SELECT swinv_apply_human_decision($1::int, $2::text, $3::text, $4::text, $5::boolean, $6::boolean, $7::text) AS result",
                 "={{ [ $json.review_id, $json.software_name, $json.vendor_name, $json.category_code, $json.is_component, $json.create_rule, $json.actor ] }}",
                 1560, Y + 60)
    n_done = node('Форма: збережено', 'n8n-nodes-base.form', 2.5,
                  {"operation": "completion", "respondWith": "text", "completionTitle": "Збережено ✔",
                   "completionMessage": "={{ $json.result.error ? ('Помилка: ' + $json.result.error) : ('«' + $json.result.software + '» → ' + $json.result.category + ($json.result.rule_id ? '. Створено правило #' + $json.result.rule_id + ' — AI більше не питатимуть про цей пакет.' : '.') + ' Зміни записано в audit_log.') }}",
                   "options": {}},
                  1820, Y + 60, webhookId="swinv-review-done-0001")
    nodes += [n_trigger, n_take, n_if, n_empty, n_build, n_page, n_parse, n_apply, n_done]
    nodes.append(sticky("## Людина в контурі (human-in-the-loop)\nn8n Form → наступний запис черги → категорії з довідника (закритий перелік) → рішення з пріоритетом **human=400** (перекриває AI/правила назавжди) → опційно правило точного збігу → audit_log.\nURL: /form/inventory/review", -40, Y - 220, 900, 140, 6))
    c = conns
    connect(c, n_trigger['name'], n_take['name'])
    connect(c, n_take['name'], n_if['name'])
    connect(c, n_if['name'], n_empty['name'], 0)
    connect(c, n_if['name'], n_build['name'], 1)
    connect(c, n_build['name'], n_page['name'])
    connect(c, n_page['name'], n_parse['name'])
    connect(c, n_parse['name'], n_apply['name'])
    connect(c, n_apply['name'], n_done['name'])
    return workflow(WF_REVIEW_ID, 'SWInv · 2. Перевірка людиною (форма)', nodes, conns, settings={"errorWorkflow": WF_ERROR_ID})


# ---------------------------------------------------------------------------
# Workflow 3: Dashboard
# ---------------------------------------------------------------------------
JS_RENDER = read(os.path.join(HERE, 'code', 'dashboard.js'))


def build_dashboard():
    _node_counter[0] = 0
    nodes = []
    conns = {}
    Y = 300
    n_wh = node('Webhook: GET /inventory/dashboard', 'n8n-nodes-base.webhook', 2.1,
                {"httpMethod": "GET", "path": "inventory/dashboard", "responseMode": "responseNode", "options": {}},
                0, Y, webhookId="swinv-inventory-dashboard-001")
    n_data = pg('БД: дані дашборду (один JSON)', "SELECT swinv_dashboard($1::int) AS d", r"={{ [ ($json.query && $json.query.host && /^\d+$/.test(String($json.query.host))) ? Number($json.query.host) : null ] }}", 260, Y)
    n_render = code('Рендер HTML', JS_RENDER, 520, Y)
    n_resp = node('HTML-відповідь', 'n8n-nodes-base.respondToWebhook', 1.5,
                  {"respondWith": "text", "responseBody": "={{ $json.html }}",
                   "options": {"responseHeaders": {"entries": [{"name": "Content-Type", "value": "text/html; charset=utf-8"}, {"name": "Cache-Control", "value": "no-store"}]}}},
                  780, Y)
    n_wh2 = node('Webhook: GET /inventory/api/dashboard', 'n8n-nodes-base.webhook', 2.1,
                 {"httpMethod": "GET", "path": "inventory/api/dashboard", "responseMode": "responseNode", "options": {}},
                 0, Y + 220, webhookId="swinv-inventory-dashboard-api1")
    n_data2 = pg('БД: дані дашборду (JSON API)', "SELECT swinv_dashboard($1::int) AS d", r"={{ [ ($json.query && $json.query.host && /^\d+$/.test(String($json.query.host))) ? Number($json.query.host) : null ] }}", 260, Y + 220)
    n_resp2 = node('JSON-відповідь', 'n8n-nodes-base.respondToWebhook', 1.5,
                   {"respondWith": "json", "responseBody": "={{ JSON.stringify($json.d) }}",
                    "options": {"responseHeaders": {"entries": [{"name": "Content-Type", "value": "application/json; charset=utf-8"}]}}},
                   520, Y + 220)
    nodes += [n_wh, n_data, n_render, n_resp, n_wh2, n_data2, n_resp2]
    nodes.append(sticky("## Дашборд реєстру ПЗ\nОдин виклик `swinv_dashboard()` → один JSON → HTML без зовнішніх залежностей (працює офлайн).\nHTML: /webhook/inventory/dashboard (?host=<id> — один хост) · JSON: /webhook/inventory/api/dashboard", -40, Y - 200, 820, 120, 3))
    c = conns
    connect(c, n_wh['name'], n_data['name'])
    connect(c, n_data['name'], n_render['name'])
    connect(c, n_render['name'], n_resp['name'])
    connect(c, n_wh2['name'], n_data2['name'])
    connect(c, n_data2['name'], n_resp2['name'])
    return workflow(WF_DASH_ID, 'SWInv · 3. Дашборд реєстру ПЗ', nodes, conns, settings={"errorWorkflow": WF_ERROR_ID})


# ---------------------------------------------------------------------------
# Workflow 4: Error trigger -> audit_log
# ---------------------------------------------------------------------------

def build_errors():
    _node_counter[0] = 0
    nodes = []
    conns = {}
    n_err = node('Помилка будь-якого воркфлоу SWInv', 'n8n-nodes-base.errorTrigger', 1, {}, 0, 300)
    n_log = pg('БД: запис у audit_log',
               "INSERT INTO audit_log (table_name, operation, row_key, new_row, actor, note) VALUES ('n8n_workflow', 'error', $1::text, $2::jsonb, 'n8n', $3::text) RETURNING id",
               "={{ [ ($json.workflow && $json.workflow.name) || 'unknown', JSON.stringify({ execution: $json.execution, workflow: $json.workflow }), String(($json.execution && $json.execution.error && $json.execution.error.message) || 'error').slice(0, 500) ] }}",
               260, 300)
    nodes += [n_err, n_log]
    nodes.append(sticky("## Обробка помилок\nБудь-яка помилка воркфлоу SWInv фіксується в audit_log (видно на дашборді). Сюди ж можна додати Telegram/Email-сповіщення.", -40, 120, 600, 110, 2))
    connect(conns, n_err['name'], n_log['name'])
    return workflow(WF_ERROR_ID, 'SWInv · 4. Обробка помилок', nodes, conns)


if __name__ == '__main__':
    wfs = [('01-ingest-classify.json', build_ingest()), ('02-review-form.json', build_review()),
           ('03-dashboard.json', build_dashboard()), ('04-error-handler.json', build_errors())]
    for fn, wf in wfs:
        p = os.path.join(OUT, fn)
        with io.open(p, 'w', encoding='utf-8') as f:
            json.dump(wf, f, ensure_ascii=False, indent=2)
        print('written', p, '| nodes:', len(wf['nodes']))

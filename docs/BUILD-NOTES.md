# Verified build notes (tested on this machine, 2026-09-08) — READ BEFORE BUILDING

## Stack (already running via docker compose, project `swinv`)
- n8n 2.37.10 at http://localhost:5678 (owner: see .env N8N_OWNER_*), Postgres 16 (`swinv-postgres`, port 5432, user n8n / pw from .env, DBs: `n8n` (n8n metadata) and `inventory` (ours)), Ollama 0.33 (`swinv-ollama`, GPU RTX 4090, model `qwen2.5:14b` pulled; ~66 tok/s, ~30 s cold load).
- Inside docker network: postgres host = `postgres`, ollama base URL = `http://ollama:11434`.
- Credentials already imported with FIXED ids (reference them exactly like this in workflow JSON):
  - `"credentials": {"postgres": {"id": "swinvPostgres01", "name": "SWInv Postgres (inventory)"}}`
  - `"credentials": {"ollamaApi": {"id": "swinvOllama0001", "name": "SWInv Ollama (local GPU)"}}`
  - `"credentials": {"httpHeaderAuth": {"id": "swinvWebhookTok", "name": "SWInv Collector Token (header X-Inventory-Token)"}}` (header name `X-Inventory-Token`, value = .env INVENTORY_WEBHOOK_TOKEN)

## Importing workflows (verified)
- Workflow JSON MUST contain a top-level fixed `"id"` (16 chars, e.g. `swinvIngest00001`) or CLI import fails with a not-null violation. Use stable ids: they are also what `Execute Sub-workflow` nodes reference.
- Commands (from the repository root, Git Bash needs `export MSYS_NO_PATHCONV=1`):
  `docker cp file.json swinv-n8n:/tmp/x.json && docker compose exec -T n8n n8n import:workflow --input=/tmp/x.json`
  `docker compose exec -T n8n n8n update:workflow --id=<id> --active=true` then `docker compose restart n8n` (activation via CLI needs a restart to register webhooks). Re-importing the same id overwrites the workflow (upsert).
- Workflow JSON skeleton: `{"id","name","nodes":[...],"connections":{...},"settings":{"executionOrder":"v1"},"active":false}`. Every node needs `id`, `name`, `type`, `typeVersion`, `position`, `parameters`; webhook-type nodes need a stable `webhookId`.
- Generate workflow JSON with a script (python `json.dump(..., ensure_ascii=False)`) instead of hand-typing escapes — hand-written `\(` in jsCode strings already broke one import.

## Node versions to use (n8n 2.37.10)
webhook 2.1 · respondToWebhook 1.5 · postgres 2.7 · code 2 · set 3.5 · if 2.3 · splitInBatches 3 · aggregate 1 · httpRequest 4.5 · scheduleTrigger 1.4 · executeWorkflow 1.3 · executeWorkflowTrigger 1.2 · formTrigger 2.6 · form 2.5 · @n8n/n8n-nodes-langchain.chainLlm 1.9 · outputParserStructured 1.3 · lmChatOllama 1 · lmChatOpenAi 1.3 (optional swap).

## Postgres node (verified)
- `operation: executeQuery`, SQL in `query`, params in `options.queryReplacement`. DO NOT use the comma-separated string form (values with commas break). Use an expression that returns a JS array:
  `"options": {"queryReplacement": "={{ [ $json.body.name, JSON.stringify($json.body.obj), $json.n, $json.arr ] }}"}` → `$1::text, $2::jsonb, $3::int, $4::text[]` all worked (Cyrillic, commas, JSON→jsonb, JS array→text[]).
- For bulk work prefer ONE query with `jsonb_to_recordset($1::jsonb)` (pass `JSON.stringify(array)`) instead of per-item queries — fast and atomic.
- Node runs once per input item by default; to run once total, feed it a single item (Aggregate / Code returning one item).
- `options.queryBatching`: `single` (default), `independently`, `transaction`.

## Webhook (verified)
- `authentication: "headerAuth"` + httpHeaderAuth credential → wrong/missing header returns 403 "Authorization data is wrong!".
- `responseMode: "lastNode"` returns last node output; use `responseMode: "responseNode"` + Respond to Webhook (`respondWith: "text"`, option `responseHeaders` → `Content-Type: text/html; charset=utf-8`) to serve HTML dashboards.
- Body available as `$json.body`, query as `$json.query`, headers as `$json.headers`.

## Code node (verified, task runner mode)
- `require('crypto')` (and other builtins) is DISALLOWED → do hashing in SQL (`md5()`) or avoid it. `$env.INVENTORY_WEBHOOK_TOKEN` and `$env.OLLAMA_MODEL` ARE readable (N8N_BLOCK_ENV_ACCESS_IN_NODE=false). `process` is undefined. Plain JS (regex, JSON, Map/Set, `String.prototype.normalize`) works.

## LLM chain (verified end-to-end in n8n)
- Basic LLM Chain `typeVersion 1.9`: `promptType: "define"`, `text: "=..."`, `hasOutputParser: true`, system prompt via `messages.messageValues[{type:"SystemMessagePromptTemplate", message:"..."}]`.
- Ollama Chat Model `typeVersion 1`: `model: "qwen2.5:14b"`, `options: {temperature: 0, format: "json", numCtx: 8192, keepAlive: "24h"}`; connect with connection type `ai_languageModel`. (Do not set `think` for qwen2.5.)
- Structured Output Parser `typeVersion 1.3`: `schemaType: "manual"`, `inputSchema: "<JSON schema string>"`; connect with `ai_outputParser`. Output lands in `$json.output`.
- Connections JSON: `"Ollama Chat Model": {"ai_languageModel": [[{"node": "<chain>", "type": "ai_languageModel", "index": 0}]]}`, same pattern for `ai_outputParser`.
- Direct Ollama API also supports `format: <json schema>` + `options.seed` for full structured output if needed via HTTP Request.
- Prompt template pitfall: LangChain treats `{` `}` in the prompt as template variables — escape braces in system prompts as `{{` `}}` if you embed JSON examples, or avoid literal braces.

## n8n Form (for human review)
- Form Trigger 2.6 (`authentication: "n8nUserAuth"` possible) → nodes → Form 2.5 (`operation: "page"`, `defineForm: "json"`, `jsonOutput: "={{ ... }}"` array of `{fieldLabel, fieldName, fieldType: dropdown|text|textarea|hiddenField|html, fieldOptions: {values:[{option:"..."}]}, requiredField}`) → Form 2.5 (`operation: "completion"`, `completionTitle`, `completionMessage`). Dynamic dropdowns = build the JSON in a Code/Set node from DB rows.

## Encoding
- Collector: UTF-8 without BOM; POST bytes with `application/json; charset=utf-8`. Git Bash curl heredocs mangle Cyrillic — test Cyrillic via files (`--data-binary @file`) or python `requests`.

## Respond to Webhook headers (verified schema)
`"options": {"responseHeaders": {"entries": [{"name": "Content-Type", "value": "text/html; charset=utf-8"}]}}` with `respondWith: "text"`, `responseBody: "={{ $json.html }}"`.

## Verified later (2026-09-08, full run)
- n8n Form flow: POST page 1 (multipart, `field-0`…) returns `{"formWaitingUrl": ".../form-waiting/<execId>?signature=…"}`; GET it renders page 2 (JSON-defined fields, dropdown defaults work via `defaultValue`), POST page 2 fields (`field-1`… in definition order, html blocks count as `field-0`) completes the flow.
- Deleting workflows: internal REST `DELETE /rest/workflows/<id>` returned 400 for active workflows; deleting rows from `webhook_entity`, `shared_workflow`, `workflow_history`, `execution_entity`, `workflow_entity` in the `n8n` DB works (restart n8n afterwards).
- Replaying the same sample file twice: `swinv_upsert_host_run` now issues a fresh run_id when the client run_id already exists (`client_run_id` keeps the original).
- Items waiting in review_queue (low_confidence / unknown_category) are NOT re-sent to the AI on later runs; technical failures (ai_unavailable / invalid_output) are retried and auto-resolved when the retry succeeds.
- Full e2e numbers (this PC): 562 packages (after the privacy filter) → 394 fingerprints → 324 by rules → 70 to AI (7 batches, ~9 s each on RTX 4090) → 69 accepted, 1 to review; second run: 0 AI calls.

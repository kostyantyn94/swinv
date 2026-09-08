#!/usr/bin/env bash
# =====================================================================
#  SWInv one-command bootstrap for Linux / macOS hosts (mirror of setup.ps1).
#  Docker stack (n8n + PostgreSQL + Ollama), database schema and dictionaries, n8n owner account,
#  credentials, workflows (imported + activated), local LLM model, smoke test.
#
#  Idempotent: safe to run again. Options:
#    --reset            wipe volumes first (fresh state; the model is downloaded again)
#    --skip-model-pull  do not pull the Ollama model
#    --skip-smoke       do not POST the sample inventory
#  Requirements: docker (compose v2), curl, bash 3.2+. GPU: Linux with nvidia-container-toolkit
#  (auto-detected); on macOS run Ollama natively and set OLLAMA_BASE_URL=http://host.docker.internal:11434.
# =====================================================================
set -u
cd "$(dirname "$0")"
RESET=0; SKIP_MODEL=0; SKIP_SMOKE=0
for a in "$@"; do case "$a" in --reset) RESET=1 ;; --skip-model-pull) SKIP_MODEL=1 ;; --skip-smoke) SKIP_SMOKE=1 ;; -h|--help) sed -n '2,14p' "$0"; exit 0 ;; esac; done

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    [ok] %s\n' "$*"; }
warn() { printf '    [!!] %s\n' "$*"; }
fail() { printf '    [xx] %s\n' "$*"; exit 1; }
wait_http() { local i=0; while [ $i -lt 60 ]; do curl -fsS -m 5 "$1" >/dev/null 2>&1 && return 0; sleep 3; i=$((i+1)); done; fail "$2 not healthy: $1"; }
psqlf() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$INVENTORY_DB" -q -f "$1" 2>&1 | grep -v NOTICE | grep -iE 'error' && fail "psql failed for $1"; return 0; }
scalar() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$1" -tAc "$2" 2>/dev/null | tr -d '\r' | sed '/^$/d'; }

step "Preflight: Docker"
docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 || fail "Docker engine is not running"
ok "Docker engine $(docker info --format '{{.ServerVersion}}')"

step ".env"
if [ ! -f .env ]; then
  cp .env.example .env
  sed -i.bak "s/^N8N_ENCRYPTION_KEY=.*/N8N_ENCRYPTION_KEY=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')/" .env
  sed -i.bak "s/^INVENTORY_WEBHOOK_TOKEN=.*/INVENTORY_WEBHOOK_TOKEN=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')/" .env
  rm -f .env.bak; ok "created .env with fresh secrets"
else ok ".env exists"; fi
set -a; . ./.env; set +a
: "${OLLAMA_BASE_URL:=http://ollama:11434}"
for k in POSTGRES_USER POSTGRES_PASSWORD INVENTORY_DB N8N_OWNER_EMAIL N8N_OWNER_PASSWORD INVENTORY_WEBHOOK_TOKEN OLLAMA_MODEL; do
  eval "v=\${$k:-}"; [ -n "$v" ] || fail ".env is missing $k"
done
if ! grep -q '^COMPOSE_FILE=' .env; then
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
    printf '\nCOMPOSE_PATH_SEPARATOR=:\nCOMPOSE_FILE=docker-compose.yml:docker-compose.gpu.yml\n' >> .env
    export COMPOSE_PATH_SEPARATOR=: COMPOSE_FILE=docker-compose.yml:docker-compose.gpu.yml
    ok "NVIDIA runtime detected: GPU override enabled"
  else warn "no NVIDIA runtime: Ollama runs on CPU (or point OLLAMA_BASE_URL to a native Ollama)"; fi
fi

if [ "$RESET" -eq 1 ]; then step "Reset: docker compose down -v"; docker compose down -v --remove-orphans >/dev/null 2>&1; ok "volumes removed"; fi
step "docker compose up -d"
docker compose up -d || fail "docker compose up failed"
wait_http http://localhost:5678/healthz n8n; ok "n8n is up"
i=0; until docker compose exec -T postgres pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1 || [ $i -ge 40 ]; do sleep 2; i=$((i+1)); done; ok "postgres is ready"

step "Inventory database: schema + dictionaries"
[ "$(scalar postgres "select 1 from pg_database where datname='$INVENTORY_DB'")" = "1" ] || docker compose exec -T postgres createdb -U "$POSTGRES_USER" "$INVENTORY_DB"
docker cp db/schema.sql swinv-postgres:/tmp/schema.sql >/dev/null; docker cp db/seed.sql swinv-postgres:/tmp/seed.sql >/dev/null
psqlf /tmp/schema.sql; psqlf /tmp/seed.sql
ok "dictionaries: $(scalar "$INVENTORY_DB" "select (select count(*) from dict_category)||' categories, '||(select count(*) from dict_vendor)||' vendors, '||(select count(*) from dict_rules)||' rules'")"

step "n8n owner account"
i=0; SETTINGS=""; while [ $i -lt 60 ]; do SETTINGS=$(curl -fsS -m 10 http://localhost:5678/rest/settings 2>/dev/null || true); case "$SETTINGS" in "{"*) break ;; esac; sleep 3; i=$((i+1)); done
case "$SETTINGS" in "{"*) ;; *) fail "n8n REST API not ready" ;; esac
if printf '%s' "$SETTINGS" | grep -q '"showSetupOnFirstLoad":true'; then
  curl -fsS -m 30 -X POST http://localhost:5678/rest/owner/setup -H 'Content-Type: application/json' \
    -d "{\"email\":\"$N8N_OWNER_EMAIL\",\"firstName\":\"${N8N_OWNER_FIRSTNAME:-Admin}\",\"lastName\":\"${N8N_OWNER_LASTNAME:-SWInv}\",\"password\":\"$N8N_OWNER_PASSWORD\"}" >/dev/null || fail "owner setup failed"
  ok "owner created: $N8N_OWNER_EMAIL"
else ok "owner already set up"; fi

step "n8n credentials"
sed -e "s#__INVENTORY_DB__#$INVENTORY_DB#; s#__POSTGRES_USER__#$POSTGRES_USER#; s#__POSTGRES_PASSWORD__#$POSTGRES_PASSWORD#; s#__INVENTORY_WEBHOOK_TOKEN__#$INVENTORY_WEBHOOK_TOKEN#; s#__OLLAMA_BASE_URL__#$OLLAMA_BASE_URL#" \
  n8n/credentials/credentials.template.json > /tmp/swinv-credentials.json
docker cp /tmp/swinv-credentials.json swinv-n8n:/tmp/credentials.json >/dev/null; rm -f /tmp/swinv-credentials.json
docker compose exec -T n8n n8n import:credentials --input=/tmp/credentials.json 2>&1 | grep -i imported | sed 's/^/    [ok] /'

step "n8n workflows: import + activate"
for f in n8n/workflows/*.json; do
  docker cp "$f" "swinv-n8n:/tmp/$(basename "$f")" >/dev/null
  docker compose exec -T n8n n8n import:workflow --input="/tmp/$(basename "$f")" 2>&1 | grep -i imported | sed "s/^/    [ok] $(basename "$f"): /"
  id=$(grep -o '"id": *"[^"]*"' "$f" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  docker compose exec -T n8n n8n update:workflow --id="$id" --active=true >/dev/null 2>&1
done
docker compose restart n8n >/dev/null 2>&1; wait_http http://localhost:5678/healthz n8n; sleep 5
scalar "${POSTGRES_DB:-n8n}" "select method||' /webhook/'||\"webhookPath\" from webhook_entity order by 1" | sed 's/^/    [ok] /'

step "Ollama model $OLLAMA_MODEL"
if curl -fsS -m 10 "${OLLAMA_BASE_URL/ollama:11434/localhost:11434}/api/tags" 2>/dev/null | grep -q "\"$OLLAMA_MODEL\""; then ok "model present"
elif [ "$SKIP_MODEL" -eq 1 ]; then warn "model missing (--skip-model-pull)"
else docker compose exec -T ollama ollama pull "$OLLAMA_MODEL" || fail "ollama pull failed"; ok "model pulled"; fi
curl -fsS -m 300 -X POST "${OLLAMA_BASE_URL/ollama:11434/localhost:11434}/api/generate" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$OLLAMA_MODEL\",\"prompt\":\"Reply with OK\",\"stream\":false,\"keep_alive\":\"24h\",\"options\":{\"num_predict\":2}}" >/dev/null 2>&1 && ok "model warmed up" || warn "warm-up skipped"

if [ "$SKIP_SMOKE" -eq 0 ] && [ -f samples/inventory-sample.json ]; then
  step "Smoke test: POST samples/inventory-sample.json"
  RESP=$(curl -sS -m 300 -X POST http://localhost:5678/webhook/inventory/ingest -H "X-Inventory-Token: $INVENTORY_WEBHOOK_TOKEN" -H 'Content-Type: application/json; charset=utf-8' --data-binary @samples/inventory-sample.json)
  ok "webhook answered: $RESP"
  RUN_ID=$(printf '%s' "$RESP" | sed -n 's/.*"run_id":"\([^"]*\)".*/\1/p')
  i=0; ROW=""; while [ $i -lt 180 ]; do ROW=$(scalar "$INVENTORY_DB" "select status||' | packages='||packages_total||' known='||known_before||' rules='||resolved_rule||' ai='||resolved_ai||' ai_calls='||ai_calls||' unresolved='||unresolved||' dict_changes='||dict_changes from inventory_runs where run_id='$RUN_ID'"); case "$ROW" in done*) break ;; esac; sleep 5; i=$((i+1)); done
  ok "$ROW"
fi

step "Ready"
printf '  n8n editor  : http://localhost:5678  (login %s / see .env)\n' "$N8N_OWNER_EMAIL"
printf '  Dashboard   : http://localhost:5678/webhook/inventory/dashboard\n  Review form : http://localhost:5678/form/inventory/review\n  JSON API    : http://localhost:5678/webhook/inventory/api/dashboard\n'
printf '  Collector   : ./collector/collect-inventory.sh   (Windows: collector\\Collect-Inventory.ps1)\n\n'

-- =====================================================================
--  SWInv — Software Inventory & AI Classification
--  Схема БД «inventory»: довідники (dict_*), інвентар (inventory_*),
--  черга перевірки, журнал аудиту, функції оновлення довідників.
--  Ідемпотентна: можна виконувати повторно (CREATE IF NOT EXISTS / OR REPLACE).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ДОВІДНИКИ
-- ---------------------------------------------------------------------

-- Закрита таксономія категорій ПЗ + політика використання в банку
CREATE TABLE IF NOT EXISTS dict_category (
  code        text PRIMARY KEY,
  name_uk     text NOT NULL,
  name_en     text NOT NULL,
  description text,
  policy      text NOT NULL DEFAULT 'allowed' CHECK (policy IN ('allowed','restricted','prohibited')),
  sort_order  int  NOT NULL DEFAULT 100,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Вендори (виробники ПЗ). name_key — нормалізований ключ, aliases — інші написання (теж нормалізовані)
CREATE TABLE IF NOT EXISTS dict_vendor (
  id          serial PRIMARY KEY,
  name        text NOT NULL,
  name_key    text NOT NULL UNIQUE,
  aliases     text[] NOT NULL DEFAULT '{}',
  created_by  text NOT NULL DEFAULT 'seed' CHECK (created_by IN ('seed','rule','ai','human')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Канонічні програмні продукти (одиниця обліку). Категорія живе ТУТ, а не на пакеті.
CREATE TABLE IF NOT EXISTS dict_software (
  id              serial PRIMARY KEY,
  product_key     text NOT NULL UNIQUE,            -- нормалізована назва + '|' + ключ вендора
  name            text NOT NULL,
  vendor_id       int REFERENCES dict_vendor(id),
  category_code   text NOT NULL REFERENCES dict_category(code),
  description     text,
  policy_override text CHECK (policy_override IN ('allowed','restricted','prohibited')),
  winget_id       text,
  created_by      text NOT NULL DEFAULT 'ai' CHECK (created_by IN ('seed','rule','ai','human')),
  confidence      numeric(4,3),
  model           text,
  prompt_version  text,
  evidence        jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS dict_software_winget_idx ON dict_software (winget_id) WHERE winget_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS dict_software_category_idx ON dict_software (category_code);

-- Правила як дані: детерміноване зіставлення пакет -> продукт/категорія БЕЗ AI
CREATE TABLE IF NOT EXISTS dict_rules (
  id            serial PRIMARY KEY,
  name          text NOT NULL,
  field         text NOT NULL DEFAULT 'name'
                CHECK (field IN ('name','name_normalized','publisher','source_key','winget_id','source')),
  pattern       text NOT NULL,                     -- POSIX regex, без урахування регістру (~*)
  software_name text,                              -- NULL => продукт = очищена назва пакета
  vendor_name   text,                              -- NULL => видавець пакета
  category_code text NOT NULL REFERENCES dict_category(code),
  is_component  boolean NOT NULL DEFAULT false,    -- пакет є складовою більшого продукту
  priority      int NOT NULL DEFAULT 100,          -- більше = важливіше
  origin        text NOT NULL DEFAULT 'seed' CHECK (origin IN ('seed','human')),
  enabled       boolean NOT NULL DEFAULT true,
  hit_count     bigint NOT NULL DEFAULT 0,
  last_hit_at   timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Зіставлення «відбиток пакета -> продукт». Пріоритет джерела рішення:
--   human(400) > seed(350) > rule(300) > exact(200) > ai(100). Нижчий пріоритет НІКОЛИ не перезаписує вищий.
CREATE TABLE IF NOT EXISTS dict_package_map (
  fingerprint      text PRIMARY KEY,
  software_id      int NOT NULL REFERENCES dict_software(id),
  match_type       text NOT NULL CHECK (match_type IN ('human','rule','exact','ai','seed')),
  priority         int NOT NULL,
  is_component     boolean NOT NULL DEFAULT false,
  confidence       numeric(4,3),
  decided_by       text NOT NULL,
  rule_id          int REFERENCES dict_rules(id) ON DELETE SET NULL,
  model            text,
  prompt_version   text,
  evidence         jsonb,
  sample_name      text,
  sample_publisher text,
  sample_source    text,
  norm_version     text NOT NULL DEFAULT 'norm_v1',
  first_seen       timestamptz NOT NULL DEFAULT now(),
  last_seen        timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS dict_package_map_software_idx ON dict_package_map (software_id);
CREATE UNIQUE INDEX IF NOT EXISTS dict_rules_name_uq ON dict_rules (name);

-- ---------------------------------------------------------------------
-- 2. ІНВЕНТАР
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inventory_hosts (
  id           serial PRIMARY KEY,
  machine_id   text NOT NULL UNIQUE,
  hostname     text NOT NULL,
  domain       text,
  os_name      text, os_version text, os_build text, os_arch text,
  last_user    text,
  manufacturer text, model text, serial text,
  first_seen   timestamptz NOT NULL DEFAULT now(),
  last_seen    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS inventory_runs (
  id                serial PRIMARY KEY,
  run_id            uuid NOT NULL UNIQUE,
  host_id           int NOT NULL REFERENCES inventory_hosts(id),
  collected_at      timestamptz,
  received_at       timestamptz NOT NULL DEFAULT now(),
  finished_at       timestamptz,
  collector_version text,
  sources           jsonb,
  packages_total    int NOT NULL DEFAULT 0,
  added             int NOT NULL DEFAULT 0,
  changed           int NOT NULL DEFAULT 0,
  removed           int NOT NULL DEFAULT 0,
  unchanged         int NOT NULL DEFAULT 0,
  fingerprints_total int NOT NULL DEFAULT 0,
  known_before      int NOT NULL DEFAULT 0,   -- відбитки, що вже були в довіднику до цього запуску
  resolved_exact    int NOT NULL DEFAULT 0,   -- нові відбитки, закриті точним збігом (winget id)
  resolved_rule     int NOT NULL DEFAULT 0,   -- нові відбитки, закриті правилами
  resolved_ai       int NOT NULL DEFAULT 0,   -- нові відбитки, закриті AI
  unresolved        int NOT NULL DEFAULT 0,   -- залишились без продукту (у черзі перевірки)
  ai_calls          int NOT NULL DEFAULT 0,
  ai_packages       int NOT NULL DEFAULT 0,
  ai_batches_failed int NOT NULL DEFAULT 0,
  dict_changes      int NOT NULL DEFAULT 0,   -- записів аудиту довідників за цей запуск
  duration_ms       int,
  status            text NOT NULL DEFAULT 'received' CHECK (status IN ('received','classifying','done','error')),
  error             text
);
ALTER TABLE inventory_runs ADD COLUMN IF NOT EXISTS client_run_id text;

CREATE TABLE IF NOT EXISTS inventory_packages (
  id                   bigserial PRIMARY KEY,
  host_id              int NOT NULL REFERENCES inventory_hosts(id),
  source               text NOT NULL,
  source_key           text NOT NULL,
  scope                text,
  arch                 text,
  name                 text NOT NULL,
  name_clean           text,
  name_normalized      text,
  publisher            text,
  publisher_normalized text,
  version              text,
  install_date         date,
  install_location     text,
  size_kb              bigint,
  is_system_component  boolean NOT NULL DEFAULT false,
  is_framework         boolean NOT NULL DEFAULT false,
  uninstall_string     text,
  winget_id            text,
  winget_source        text,
  winget_available_version text,
  raw                  jsonb,
  fingerprint          text NOT NULL,
  norm_version         text NOT NULL DEFAULT 'norm_v1',
  present              boolean NOT NULL DEFAULT true,
  first_seen           timestamptz NOT NULL DEFAULT now(),
  last_seen            timestamptz NOT NULL DEFAULT now(),
  version_prev         text,
  changed_at           timestamptz,
  removed_at           timestamptz,
  first_run_id         uuid,
  last_run_id          uuid,
  UNIQUE (host_id, source, source_key)
);
CREATE INDEX IF NOT EXISTS inventory_packages_fp_idx ON inventory_packages (fingerprint);
CREATE INDEX IF NOT EXISTS inventory_packages_host_present_idx ON inventory_packages (host_id, present);

-- Черга перевірки людиною (низька впевненість AI / невідома категорія / AI недоступний)
CREATE TABLE IF NOT EXISTS review_queue (
  id                    serial PRIMARY KEY,
  fingerprint           text NOT NULL,
  host_id               int REFERENCES inventory_hosts(id),
  run_id                uuid,
  sample_name           text, sample_publisher text, sample_source text, sample_version text,
  proposed_software     text, proposed_vendor text, proposed_category text,
  proposed_is_component boolean,
  confidence            numeric(4,3),
  reason                text NOT NULL CHECK (reason IN ('low_confidence','unknown_category','invalid_output','ai_unavailable','manual')),
  ai_reason             text,
  status                text NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','dismissed')),
  created_at            timestamptz NOT NULL DEFAULT now(),
  resolved_at           timestamptz,
  resolved_by           text,
  resolution            jsonb
);
CREATE UNIQUE INDEX IF NOT EXISTS review_queue_open_uq ON review_queue (fingerprint) WHERE status = 'open';

-- Журнал аудиту: кожна зміна довідників (тригер на рівні рядка — обійти неможливо)
CREATE TABLE IF NOT EXISTS audit_log (
  id         bigserial PRIMARY KEY,
  at         timestamptz NOT NULL DEFAULT now(),
  table_name text NOT NULL,
  operation  text NOT NULL,
  row_key    text,
  old_row    jsonb,
  new_row    jsonb,
  actor      text NOT NULL DEFAULT 'n8n',
  run_id     uuid,
  note       text
);
CREATE INDEX IF NOT EXISTS audit_log_run_idx ON audit_log (run_id);
CREATE INDEX IF NOT EXISTS audit_log_at_idx ON audit_log (at DESC);

-- ---------------------------------------------------------------------
-- 3. ДОПОМІЖНІ ФУНКЦІЇ
-- ---------------------------------------------------------------------

-- Ключ продукту з назви, що надійшла від правила/AI/людини (назви вже без версій)
CREATE OR REPLACE FUNCTION swinv_key(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(trim(regexp_replace(regexp_replace(lower(coalesce(p,'')), '[™®©]', '', 'g'), '\s+', ' ', 'g')), '')
$$;

-- Ключ вендора: без організаційно-правових суфіксів і пунктуації (дзеркало norm_v1 у n8n)
CREATE OR REPLACE FUNCTION swinv_vendor_key(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(trim(regexp_replace(regexp_replace(regexp_replace(
           lower(coalesce(p,'')),
           '[™®©,.]', ' ', 'g'),
           '(^|\s)(inc|incorporated|corp|corporation|co|company|ltd|limited|llc|gmbh|sro|s r o|plc|ag|sa|srl|bv|oy|ab|pte|pty|the|software|team|foundation|technologies|technology|systems|корпорація|корпорация|тов|ооо|компанія|компания)(?=\s|$)', ' ', 'g'),
           '\s+', ' ', 'g')), '')
$$;

CREATE OR REPLACE FUNCTION swinv_regex_escape(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(coalesce(p,''), '([.^$*+?()\[\]{}|\\])', '\\\1', 'g')
$$;

CREATE OR REPLACE FUNCTION swinv_priority(p_match_type text) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_match_type WHEN 'human' THEN 400 WHEN 'seed' THEN 350 WHEN 'rule' THEN 300 WHEN 'exact' THEN 200 ELSE 100 END
$$;

-- Актор/запуск для аудиту: встановлюється функціями на час транзакції
CREATE OR REPLACE FUNCTION swinv_set_actor(p_actor text, p_run_id uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('swinv.actor', coalesce(p_actor,'n8n'), true),
         set_config('swinv.run_id', coalesce(p_run_id::text,''), true)
$$;

-- Вендор за назвою: пошук за ключем або аліасом, інакше створення. Повертає id.
CREATE OR REPLACE FUNCTION swinv_vendor_id(p_name text, p_created_by text) RETURNS int LANGUAGE plpgsql AS $$
DECLARE k text := swinv_vendor_key(p_name); v_id int;
BEGIN
  IF k IS NULL THEN RETURN NULL; END IF;
  SELECT id INTO v_id FROM dict_vendor WHERE name_key = k OR k = ANY(aliases) ORDER BY (name_key = k) DESC LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO dict_vendor (name, name_key, created_by) VALUES (trim(p_name), k, coalesce(p_created_by,'ai'))
    ON CONFLICT (name_key) DO NOTHING RETURNING id INTO v_id;
    IF v_id IS NULL THEN SELECT id INTO v_id FROM dict_vendor WHERE name_key = k; END IF;
  END IF;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- 4. ТРИГЕРИ АУДИТУ (ігнорують «технічні» зміни: last_seen, hit_count тощо)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION swinv_audit_trigger() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_old jsonb; v_new jsonb; v_key text;
  v_volatile text[] := ARRAY['updated_at','last_seen','hit_count','last_hit_at'];
BEGIN
  IF TG_OP = 'DELETE' THEN v_old := to_jsonb(OLD); ELSE v_new := to_jsonb(NEW); END IF;
  IF TG_OP = 'UPDATE' THEN
    v_old := to_jsonb(OLD);
    IF (v_old - v_volatile) = (v_new - v_volatile) THEN RETURN NEW; END IF;
  END IF;
  v_key := coalesce(v_new->>'fingerprint', v_new->>'code', v_new->>'id', v_old->>'fingerprint', v_old->>'code', v_old->>'id');
  INSERT INTO audit_log (table_name, operation, row_key, old_row, new_row, actor, run_id)
  VALUES (TG_TABLE_NAME, TG_OP, v_key, v_old, v_new,
          coalesce(nullif(current_setting('swinv.actor', true), ''), 'n8n'),
          nullif(current_setting('swinv.run_id', true), '')::uuid);
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['dict_category','dict_vendor','dict_software','dict_rules','dict_package_map'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_audit_' || t) THEN
      EXECUTE format('CREATE TRIGGER trg_audit_%I AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION swinv_audit_trigger()', t, t);
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION swinv_touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['dict_category','dict_vendor','dict_software','dict_rules','dict_package_map'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_touch_' || t) THEN
      EXECUTE format('CREATE TRIGGER trg_touch_%I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION swinv_touch_updated_at()', t, t);
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 5. ФУНКЦІЇ ПАЙПЛАЙНУ (викликаються з n8n одним SELECT кожна; атомарні)
-- ---------------------------------------------------------------------

-- 5.1 Хост + запуск
CREATE OR REPLACE FUNCTION swinv_upsert_host_run(p_host jsonb, p_run jsonb)
RETURNS TABLE (host_id int, run_id uuid, run_pk int) LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE v_host_id int; v_run_id uuid := (p_run->>'run_id')::uuid; v_run_pk int;
BEGIN
  INSERT INTO inventory_hosts (machine_id, hostname, domain, os_name, os_version, os_build, os_arch, last_user, manufacturer, model, serial)
  VALUES (p_host->>'machine_id', p_host->>'hostname', p_host->>'domain', p_host->>'os_name', p_host->>'os_version',
          p_host->>'os_build', p_host->>'os_arch', p_host->>'user', p_host->>'manufacturer', p_host->>'model', p_host->>'serial')
  ON CONFLICT (machine_id) DO UPDATE SET
    hostname = EXCLUDED.hostname, domain = EXCLUDED.domain, os_name = EXCLUDED.os_name, os_version = EXCLUDED.os_version,
    os_build = EXCLUDED.os_build, os_arch = EXCLUDED.os_arch, last_user = EXCLUDED.last_user,
    manufacturer = EXCLUDED.manufacturer, model = EXCLUDED.model, serial = EXCLUDED.serial, last_seen = now()
  RETURNING id INTO v_host_id;

  -- повторне надсилання того самого файлу (той самий run_id) => новий запуск, а не перезапис історії
  IF EXISTS (SELECT 1 FROM inventory_runs r WHERE r.run_id = v_run_id) THEN v_run_id := gen_random_uuid(); END IF;

  INSERT INTO inventory_runs (run_id, client_run_id, host_id, collected_at, collector_version, sources, packages_total, status)
  VALUES (v_run_id, p_run->>'run_id', v_host_id, nullif(p_run->>'collected_at','')::timestamptz, p_run->>'collector_version',
          p_run->'sources', coalesce((p_run->>'packages_total')::int, 0), 'received')
  RETURNING id INTO v_run_pk;

  RETURN QUERY SELECT v_host_id, v_run_id, v_run_pk;
END $$;

-- 5.2 Set-based upsert пакетів + diff (added / changed / removed)
CREATE OR REPLACE FUNCTION swinv_ingest_packages(p_host_id int, p_run_id uuid, p_packages jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_added int; v_changed int; v_removed int; v_unchanged int; v_total int;
BEGIN
  PERFORM swinv_set_actor('collector', p_run_id);

  CREATE TEMP TABLE tmp_inp ON COMMIT DROP AS
  SELECT * FROM jsonb_to_recordset(p_packages) AS x(
    source text, source_key text, scope text, arch text, name text, name_clean text, name_normalized text,
    publisher text, publisher_normalized text, version text, install_date date, install_location text, size_kb bigint,
    is_system_component boolean, is_framework boolean, uninstall_string text,
    winget_id text, winget_source text, winget_available_version text, raw jsonb, fingerprint text, norm_version text);

  -- стан ДО оновлення
  SELECT count(*) FILTER (WHERE e.id IS NULL OR NOT e.present),
         count(*) FILTER (WHERE e.id IS NOT NULL AND e.present AND e.version IS DISTINCT FROM i.version),
         count(*) FILTER (WHERE e.id IS NOT NULL AND e.present AND e.version IS NOT DISTINCT FROM i.version),
         count(*)
    INTO v_added, v_changed, v_unchanged, v_total
  FROM tmp_inp i LEFT JOIN inventory_packages e
    ON e.host_id = p_host_id AND e.source = i.source AND e.source_key = i.source_key;

  INSERT INTO inventory_packages (host_id, source, source_key, scope, arch, name, name_clean, name_normalized, publisher, publisher_normalized,
     version, install_date, install_location, size_kb, is_system_component, is_framework, uninstall_string,
     winget_id, winget_source, winget_available_version, raw, fingerprint, norm_version, present, first_seen, last_seen, first_run_id, last_run_id)
  SELECT p_host_id, source, source_key, scope, arch, name, name_clean, name_normalized, publisher, publisher_normalized,
     version, install_date, install_location, size_kb, coalesce(is_system_component,false), coalesce(is_framework,false), uninstall_string,
     winget_id, winget_source, winget_available_version, raw, fingerprint, coalesce(norm_version,'norm_v1'), true, now(), now(), p_run_id, p_run_id
  FROM tmp_inp
  ON CONFLICT (host_id, source, source_key) DO UPDATE SET
     scope = EXCLUDED.scope, arch = EXCLUDED.arch, name = EXCLUDED.name, name_clean = EXCLUDED.name_clean,
     name_normalized = EXCLUDED.name_normalized, publisher = EXCLUDED.publisher, publisher_normalized = EXCLUDED.publisher_normalized,
     version_prev = CASE WHEN inventory_packages.version IS DISTINCT FROM EXCLUDED.version THEN inventory_packages.version ELSE inventory_packages.version_prev END,
     changed_at   = CASE WHEN inventory_packages.version IS DISTINCT FROM EXCLUDED.version THEN now() ELSE inventory_packages.changed_at END,
     version = EXCLUDED.version, install_date = EXCLUDED.install_date, install_location = EXCLUDED.install_location, size_kb = EXCLUDED.size_kb,
     is_system_component = EXCLUDED.is_system_component, is_framework = EXCLUDED.is_framework, uninstall_string = EXCLUDED.uninstall_string,
     winget_id = EXCLUDED.winget_id, winget_source = EXCLUDED.winget_source, winget_available_version = EXCLUDED.winget_available_version,
     raw = EXCLUDED.raw, fingerprint = EXCLUDED.fingerprint, norm_version = EXCLUDED.norm_version,
     present = true, removed_at = NULL, last_seen = now(), last_run_id = p_run_id;

  -- пакети хоста, яких немає у цьому знімку -> видалені
  UPDATE inventory_packages e SET present = false, removed_at = now(), last_run_id = p_run_id
  WHERE e.host_id = p_host_id AND e.present AND e.last_run_id IS DISTINCT FROM p_run_id;
  GET DIAGNOSTICS v_removed = ROW_COUNT;

  UPDATE inventory_runs SET packages_total = v_total, added = v_added, changed = v_changed, removed = v_removed,
         unchanged = v_unchanged, status = 'classifying',
         fingerprints_total = (SELECT count(DISTINCT fingerprint) FROM inventory_packages WHERE host_id = p_host_id AND present),
         known_before = (SELECT count(DISTINCT p.fingerprint) FROM inventory_packages p JOIN dict_package_map m ON m.fingerprint = p.fingerprint
                         WHERE p.host_id = p_host_id AND p.present)
  WHERE run_id = p_run_id;

  RETURN jsonb_build_object('packages_total', v_total, 'added', v_added, 'changed', v_changed, 'removed', v_removed, 'unchanged', v_unchanged);
END $$;

-- 5.3 Крок 1: точні збіги — відбиток уже в довіднику (touch last_seen) або winget id відомого продукту
CREATE OR REPLACE FUNCTION swinv_match_exact(p_host_id int, p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_known int; v_exact int;
BEGIN
  PERFORM swinv_set_actor('exact', p_run_id);

  UPDATE dict_package_map m SET last_seen = now()
  WHERE m.fingerprint IN (SELECT DISTINCT fingerprint FROM inventory_packages WHERE host_id = p_host_id AND present);
  GET DIAGNOSTICS v_known = ROW_COUNT;

  INSERT INTO dict_package_map (fingerprint, software_id, match_type, priority, is_component, confidence, decided_by,
                                sample_name, sample_publisher, sample_source, norm_version)
  SELECT DISTINCT ON (p.fingerprint) p.fingerprint, s.id, 'exact', swinv_priority('exact'), false, 1.0, 'exact:winget_id',
         p.name, p.publisher, p.source, p.norm_version
  FROM inventory_packages p JOIN dict_software s ON s.winget_id IS NOT NULL AND s.winget_id = p.winget_id
  WHERE p.host_id = p_host_id AND p.present
    AND NOT EXISTS (SELECT 1 FROM dict_package_map m WHERE m.fingerprint = p.fingerprint)
  ORDER BY p.fingerprint, p.id
  ON CONFLICT (fingerprint) DO NOTHING;
  GET DIAGNOSTICS v_exact = ROW_COUNT;

  UPDATE inventory_runs SET resolved_exact = v_exact WHERE run_id = p_run_id;
  RETURN jsonb_build_object('known_before', v_known, 'resolved_exact', v_exact);
END $$;

-- 5.4 Крок 2: правила (dict_rules) для нерозв'язаних відбитків
CREATE OR REPLACE FUNCTION swinv_apply_rules(p_host_id int, p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_count int; v_rules jsonb;
BEGIN
  PERFORM swinv_set_actor('rule', p_run_id);

  CREATE TEMP TABLE tmp_matched ON COMMIT DROP AS
  SELECT DISTINCT ON (u.fingerprint)
         u.fingerprint, u.name, u.name_clean, u.name_normalized, u.publisher, u.publisher_normalized, u.source, u.norm_version,
         r.id AS rule_id, r.name AS rule_name, r.is_component,
         coalesce(r.software_name, u.name_clean, u.name)            AS sw_name,
         coalesce(swinv_key(r.software_name), u.name_normalized, swinv_key(u.name)) AS sw_key,
         coalesce(r.vendor_name, u.publisher)                        AS v_name,
         NULL::int AS vendor_id, NULL::text AS v_key,
         r.category_code
  FROM (
    SELECT DISTINCT ON (p.fingerprint) p.fingerprint, p.name, p.name_clean, p.name_normalized, p.publisher, p.publisher_normalized,
           p.source, p.source_key, p.winget_id, p.norm_version
    FROM inventory_packages p
    WHERE p.host_id = p_host_id AND p.present
      AND NOT EXISTS (SELECT 1 FROM dict_package_map m WHERE m.fingerprint = p.fingerprint)
    ORDER BY p.fingerprint, p.id
  ) u
  JOIN dict_rules r ON r.enabled AND (
       CASE r.field WHEN 'name' THEN u.name WHEN 'name_normalized' THEN coalesce(u.name_normalized,'')
                    WHEN 'publisher' THEN coalesce(u.publisher,'') WHEN 'source_key' THEN u.source_key
                    WHEN 'winget_id' THEN coalesce(u.winget_id,'') WHEN 'source' THEN u.source END) ~* r.pattern
  ORDER BY u.fingerprint, r.priority DESC, r.id;

  -- вендори (пошук за ключем/аліасом або створення)
  UPDATE tmp_matched SET vendor_id = swinv_vendor_id(v_name, 'rule');
  UPDATE tmp_matched t SET v_key = v.name_key FROM dict_vendor v WHERE v.id = t.vendor_id;

  -- продукти
  INSERT INTO dict_software (product_key, name, vendor_id, category_code, created_by, confidence, evidence)
  SELECT DISTINCT ON (pk) pk, m.sw_name, m.vendor_id, m.category_code, 'rule', 1.0, jsonb_build_object('rule_id', m.rule_id, 'rule', m.rule_name)
  FROM (SELECT *, sw_key || '|' || coalesce(v_key,'') AS pk FROM tmp_matched) m
  ORDER BY pk, m.rule_id
  ON CONFLICT (product_key) DO NOTHING;

  -- зіставлення (пріоритет rule=300; захист від пониження)
  INSERT INTO dict_package_map (fingerprint, software_id, match_type, priority, is_component, confidence, decided_by, rule_id,
                                sample_name, sample_publisher, sample_source, norm_version, evidence)
  SELECT m.fingerprint, s.id, 'rule', swinv_priority('rule'), m.is_component, 1.0, 'rule:' || m.rule_id, m.rule_id,
         m.name, m.publisher, m.source, m.norm_version, jsonb_build_object('rule', m.rule_name)
  FROM tmp_matched m JOIN dict_software s ON s.product_key = m.sw_key || '|' || coalesce(m.v_key,'')
  ON CONFLICT (fingerprint) DO UPDATE SET
     software_id = EXCLUDED.software_id, match_type = EXCLUDED.match_type, priority = EXCLUDED.priority,
     is_component = EXCLUDED.is_component, decided_by = EXCLUDED.decided_by, rule_id = EXCLUDED.rule_id, evidence = EXCLUDED.evidence
  WHERE EXCLUDED.priority >= dict_package_map.priority;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  UPDATE dict_rules r SET hit_count = r.hit_count + h.n, last_hit_at = now()
  FROM (SELECT rule_id, count(*) n FROM tmp_matched GROUP BY rule_id) h WHERE h.rule_id = r.id;

  SELECT coalesce(jsonb_agg(jsonb_build_object('rule', rule_name, 'hits', n) ORDER BY n DESC), '[]'::jsonb) INTO v_rules
  FROM (SELECT rule_name, count(*) n FROM tmp_matched GROUP BY rule_name) x;

  UPDATE inventory_runs SET resolved_rule = v_count WHERE run_id = p_run_id;
  RETURN jsonb_build_object('resolved_rule', v_count, 'rules', v_rules);
END $$;

-- 5.5 Крок 3: що лишилося невідомим — на AI (по одному зразку на відбиток)
CREATE OR REPLACE FUNCTION swinv_unresolved(p_host_id int)
RETURNS TABLE (fingerprint text, name text, name_clean text, publisher text, source text, version text,
               winget_id text, is_system_component boolean, install_location text, occurrences bigint)
LANGUAGE sql STABLE AS $$
  SELECT DISTINCT ON (p.fingerprint) p.fingerprint, p.name, p.name_clean, p.publisher, p.source, p.version, p.winget_id,
         p.is_system_component, p.install_location,
         count(*) OVER (PARTITION BY p.fingerprint) AS occurrences
  FROM inventory_packages p
  WHERE p.host_id = p_host_id AND p.present
    AND NOT EXISTS (SELECT 1 FROM dict_package_map m WHERE m.fingerprint = p.fingerprint)
    -- пакети, що вже чекають на рішення людини, повторно до AI не надсилаються (AI свою думку вже висловив);
    -- виняток — технічні збої (ai_unavailable / invalid_output): їх можна спробувати ще раз
    AND NOT EXISTS (SELECT 1 FROM review_queue q WHERE q.fingerprint = p.fingerprint AND q.status = 'open'
                      AND q.reason IN ('low_confidence','unknown_category','manual'))
  ORDER BY p.fingerprint, p.id
$$;

-- 5.6 Результати AI для одного батчу (після валідації в n8n)
--  p_results: [{fingerprint, decision:'accept'|'accept_review'|'review', software_name, vendor_name, category_code,
--               is_component, confidence, reason, review_reason, sample_name, sample_publisher, sample_source, sample_version}]
CREATE OR REPLACE FUNCTION swinv_apply_ai_results(p_run_id uuid, p_host_id int, p_model text, p_prompt_version text, p_results jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_accepted int; v_review int;
BEGIN
  PERFORM swinv_set_actor('ai:' || coalesce(p_model,'?'), p_run_id);

  CREATE TEMP TABLE tmp_ai ON COMMIT DROP AS
  SELECT x.*, swinv_key(x.software_name) AS sw_key, NULL::int AS vendor_id, NULL::text AS v_key
  FROM jsonb_to_recordset(p_results) AS x(
    fingerprint text, decision text, software_name text, vendor_name text, category_code text, is_component boolean,
    confidence numeric, reason text, review_reason text, sample_name text, sample_publisher text, sample_source text, sample_version text);

  UPDATE tmp_ai SET vendor_id = swinv_vendor_id(vendor_name, 'ai') WHERE decision IN ('accept','accept_review');
  UPDATE tmp_ai t SET v_key = v.name_key FROM dict_vendor v WHERE v.id = t.vendor_id;

  INSERT INTO dict_software (product_key, name, vendor_id, category_code, created_by, confidence, model, prompt_version, evidence)
  SELECT DISTINCT ON (pk) pk, a.software_name, a.vendor_id, a.category_code, 'ai', a.confidence, p_model, p_prompt_version,
         jsonb_build_object('reason', a.reason, 'sample', a.sample_name)
  FROM (SELECT *, sw_key || '|' || coalesce(v_key,'') AS pk FROM tmp_ai WHERE decision IN ('accept','accept_review') AND sw_key IS NOT NULL) a
  ORDER BY pk, a.confidence DESC
  ON CONFLICT (product_key) DO NOTHING;

  INSERT INTO dict_package_map (fingerprint, software_id, match_type, priority, is_component, confidence, decided_by, model, prompt_version,
                                sample_name, sample_publisher, sample_source, evidence)
  SELECT a.fingerprint, s.id, 'ai', swinv_priority('ai'), coalesce(a.is_component,false), a.confidence, 'ai:' || coalesce(p_model,'?'),
         p_model, p_prompt_version, a.sample_name, a.sample_publisher, a.sample_source,
         jsonb_build_object('reason', a.reason, 'decision', a.decision)
  FROM tmp_ai a JOIN dict_software s ON s.product_key = a.sw_key || '|' || coalesce(a.v_key,'')
  WHERE a.decision IN ('accept','accept_review')
  ON CONFLICT (fingerprint) DO UPDATE SET
     software_id = EXCLUDED.software_id, match_type = EXCLUDED.match_type, priority = EXCLUDED.priority,
     is_component = EXCLUDED.is_component, confidence = EXCLUDED.confidence, decided_by = EXCLUDED.decided_by,
     model = EXCLUDED.model, prompt_version = EXCLUDED.prompt_version, evidence = EXCLUDED.evidence
  WHERE EXCLUDED.priority >= dict_package_map.priority;
  GET DIAGNOSTICS v_accepted = ROW_COUNT;

  -- повторна спроба після технічного збою вдалася -> закриваємо старі технічні записи черги
  UPDATE review_queue q SET status = 'resolved', resolved_at = now(), resolved_by = 'ai-retry',
         resolution = jsonb_build_object('run_id', p_run_id, 'note', 'класифіковано при повторній спробі')
  WHERE q.status = 'open' AND q.reason IN ('ai_unavailable','invalid_output')
    AND q.fingerprint IN (SELECT fingerprint FROM tmp_ai WHERE decision = 'accept');

  INSERT INTO review_queue (fingerprint, host_id, run_id, sample_name, sample_publisher, sample_source, sample_version,
                            proposed_software, proposed_vendor, proposed_category, proposed_is_component, confidence, reason, ai_reason)
  SELECT a.fingerprint, p_host_id, p_run_id, a.sample_name, a.sample_publisher, a.sample_source, a.sample_version,
         a.software_name, a.vendor_name, a.category_code, a.is_component, a.confidence,
         CASE WHEN a.review_reason IN ('low_confidence','unknown_category','invalid_output','ai_unavailable') THEN a.review_reason ELSE 'low_confidence' END,
         a.reason
  FROM tmp_ai a WHERE a.decision IN ('review','accept_review')
  ON CONFLICT (fingerprint) WHERE status = 'open' DO NOTHING;
  GET DIAGNOSTICS v_review = ROW_COUNT;

  UPDATE inventory_runs SET ai_calls = ai_calls + 1, ai_packages = ai_packages + (SELECT count(*) FROM tmp_ai),
         resolved_ai = resolved_ai + v_accepted
  WHERE run_id = p_run_id;

  RETURN jsonb_build_object('accepted', v_accepted, 'review', v_review, 'batch', (SELECT count(*) FROM tmp_ai));
END $$;

-- 5.7 AI недоступний / невалідна відповідь: батч у чергу, запуск не падає
CREATE OR REPLACE FUNCTION swinv_ai_failed(p_run_id uuid, p_host_id int, p_batch jsonb, p_reason text, p_error text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  PERFORM swinv_set_actor('ai', p_run_id);
  INSERT INTO review_queue (fingerprint, host_id, run_id, sample_name, sample_publisher, sample_source, sample_version, reason, ai_reason)
  SELECT x.fingerprint, p_host_id, p_run_id, x.name, x.publisher, x.source, x.version,
         CASE WHEN p_reason IN ('invalid_output','ai_unavailable') THEN p_reason ELSE 'ai_unavailable' END, left(p_error, 500)
  FROM jsonb_to_recordset(p_batch) AS x(fingerprint text, name text, publisher text, source text, version text)
  ON CONFLICT (fingerprint) WHERE status = 'open' DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE inventory_runs SET ai_batches_failed = ai_batches_failed + 1, ai_calls = ai_calls + 1 WHERE run_id = p_run_id;
  RETURN jsonb_build_object('queued', v_n, 'reason', p_reason);
END $$;

-- 5.8 Фіналізація запуску: підсумкові лічильники
CREATE OR REPLACE FUNCTION swinv_finalize_run(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r inventory_runs%ROWTYPE; v_unresolved int; v_changes int; v_out jsonb;
BEGIN
  SELECT * INTO r FROM inventory_runs WHERE run_id = p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'run not found'); END IF;

  SELECT count(DISTINCT p.fingerprint) INTO v_unresolved
  FROM inventory_packages p WHERE p.host_id = r.host_id AND p.present
    AND NOT EXISTS (SELECT 1 FROM dict_package_map m WHERE m.fingerprint = p.fingerprint);
  SELECT count(*) INTO v_changes FROM audit_log WHERE run_id = p_run_id;

  UPDATE inventory_runs SET unresolved = v_unresolved, dict_changes = v_changes, status = 'done', finished_at = now(),
         duration_ms = (EXTRACT(EPOCH FROM (now() - received_at)) * 1000)::int
  WHERE run_id = p_run_id;

  SELECT to_jsonb(x) INTO v_out FROM (
    SELECT run_id, host_id, packages_total, added, changed, removed, fingerprints_total, known_before,
           resolved_exact, resolved_rule, resolved_ai, unresolved, ai_calls, ai_packages, ai_batches_failed, dict_changes, duration_ms, status
    FROM inventory_runs WHERE run_id = p_run_id) x;
  RETURN v_out;
END $$;

-- 5.9 Рішення людини з форми перевірки: human(400) перекриває все; опційно — правило точного збігу
CREATE OR REPLACE FUNCTION swinv_apply_human_decision(p_review_id int, p_software_name text, p_vendor_name text, p_category_code text,
                                                     p_is_component boolean, p_create_rule boolean, p_actor text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE q review_queue%ROWTYPE; v_vendor_id int; v_sw_id int; v_pk text; v_vkey text; v_rule_id int; v_pattern text;
BEGIN
  SELECT * INTO q FROM review_queue WHERE id = p_review_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'review item not found'); END IF;
  IF NOT EXISTS (SELECT 1 FROM dict_category WHERE code = p_category_code) THEN
    RETURN jsonb_build_object('error', 'unknown category ' || coalesce(p_category_code,'?'));
  END IF;
  IF swinv_key(p_software_name) IS NULL THEN RETURN jsonb_build_object('error', 'empty software name'); END IF;
  PERFORM swinv_set_actor('human:' || coalesce(p_actor,'reviewer'), q.run_id);

  v_vendor_id := swinv_vendor_id(p_vendor_name, 'human');
  SELECT name_key INTO v_vkey FROM dict_vendor WHERE id = v_vendor_id;

  v_pk := swinv_key(p_software_name) || '|' || coalesce(v_vkey,'');
  INSERT INTO dict_software (product_key, name, vendor_id, category_code, created_by, confidence, evidence)
  VALUES (v_pk, trim(p_software_name), v_vendor_id, p_category_code, 'human', 1.0, jsonb_build_object('review_id', p_review_id))
  ON CONFLICT (product_key) DO UPDATE SET category_code = EXCLUDED.category_code, vendor_id = coalesce(EXCLUDED.vendor_id, dict_software.vendor_id)
  RETURNING id INTO v_sw_id;

  INSERT INTO dict_package_map (fingerprint, software_id, match_type, priority, is_component, confidence, decided_by,
                                sample_name, sample_publisher, sample_source, evidence)
  VALUES (q.fingerprint, v_sw_id, 'human', swinv_priority('human'), coalesce(p_is_component,false), 1.0, 'human:' || coalesce(p_actor,'reviewer'),
          q.sample_name, q.sample_publisher, q.sample_source, jsonb_build_object('review_id', p_review_id))
  ON CONFLICT (fingerprint) DO UPDATE SET
     software_id = EXCLUDED.software_id, match_type = 'human', priority = EXCLUDED.priority, is_component = EXCLUDED.is_component,
     confidence = 1.0, decided_by = EXCLUDED.decided_by, evidence = EXCLUDED.evidence
  WHERE EXCLUDED.priority >= dict_package_map.priority;

  IF coalesce(p_create_rule, false) AND q.sample_name IS NOT NULL THEN
    v_pattern := '^' || swinv_regex_escape(q.sample_name) || '$';
    INSERT INTO dict_rules (name, field, pattern, software_name, vendor_name, category_code, is_component, priority, origin)
    VALUES ('Рішення людини: ' || left(q.sample_name, 60), 'name', v_pattern, trim(p_software_name), nullif(trim(p_vendor_name),''),
            p_category_code, coalesce(p_is_component,false), 500, 'human')
    RETURNING id INTO v_rule_id;
  END IF;

  UPDATE review_queue SET status = 'resolved', resolved_at = now(), resolved_by = coalesce(p_actor,'reviewer'),
         resolution = jsonb_build_object('software_id', v_sw_id, 'software', p_software_name, 'vendor', p_vendor_name,
                                         'category', p_category_code, 'is_component', p_is_component, 'rule_id', v_rule_id)
  WHERE id = p_review_id;
  -- інші відкриті записи з тим самим відбитком теж закриваємо
  UPDATE review_queue SET status = 'resolved', resolved_at = now(), resolved_by = coalesce(p_actor,'reviewer'),
         resolution = jsonb_build_object('software_id', v_sw_id, 'via_review_id', p_review_id)
  WHERE fingerprint = q.fingerprint AND status = 'open';

  RETURN jsonb_build_object('software_id', v_sw_id, 'software', p_software_name, 'vendor', p_vendor_name,
                            'category', p_category_code, 'rule_id', v_rule_id, 'fingerprint', q.fingerprint);
END $$;

-- ---------------------------------------------------------------------
-- 6. ПОДАННЯ (VIEWS)
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_policy_violations;
DROP VIEW IF EXISTS v_software_by_host;
DROP VIEW IF EXISTS v_inventory_current;

CREATE VIEW v_inventory_current AS
SELECT p.id, p.host_id, h.hostname, p.source, p.source_key, p.scope, p.arch, p.name, p.name_clean, p.publisher, p.version,
       p.install_date, p.install_location, p.is_system_component, p.winget_id, p.winget_available_version, p.fingerprint,
       p.first_seen, p.last_seen, p.version_prev, p.changed_at,
       m.software_id, m.match_type, m.priority AS match_priority, m.is_component, m.confidence, m.decided_by,
       s.name AS software_name, v.name AS vendor_name, s.category_code, c.name_uk AS category_name_uk,
       coalesce(s.policy_override, c.policy) AS policy
FROM inventory_packages p
JOIN inventory_hosts h ON h.id = p.host_id
LEFT JOIN dict_package_map m ON m.fingerprint = p.fingerprint
LEFT JOIN dict_software s ON s.id = m.software_id
LEFT JOIN dict_vendor v ON v.id = s.vendor_id
LEFT JOIN dict_category c ON c.code = s.category_code
WHERE p.present;

-- Згортання пакетів у продукти (реєстр ПЗ по хостах)
CREATE VIEW v_software_by_host AS
SELECT host_id, hostname, software_id, software_name, vendor_name, category_code, category_name_uk, policy,
       count(*) AS package_count,
       count(*) FILTER (WHERE is_component) AS component_count,
       array_remove(array_agg(DISTINCT version ORDER BY version), NULL) AS versions,
       array_agg(DISTINCT match_type) AS match_types,
       min(first_seen) AS first_seen,
       bool_or(winget_available_version IS NOT NULL) AS update_available
FROM v_inventory_current
WHERE software_id IS NOT NULL
GROUP BY host_id, hostname, software_id, software_name, vendor_name, category_code, category_name_uk, policy;

CREATE VIEW v_policy_violations AS
SELECT * FROM v_software_by_host WHERE policy IN ('prohibited','restricted');

-- ---------------------------------------------------------------------
-- 7. ДАШБОРД: один виклик -> один JSON. p_host_id = NULL -> увесь парк, інакше один хост
--    (довідники, черга перевірки, правила та аудит завжди спільні)
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS swinv_dashboard();
CREATE OR REPLACE FUNCTION swinv_dashboard(p_host_id int DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE AS $$
SELECT jsonb_build_object(
  'generated_at', now(),
  'host_filter', p_host_id,
  'host', (SELECT to_jsonb(h) FROM (
      SELECT id, hostname, domain, os_name, os_version, os_arch, last_user, manufacturer, model, first_seen, last_seen
      FROM inventory_hosts WHERE id = p_host_id) h),
  'hosts', (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.hostname), '[]'::jsonb) FROM (
      SELECT h.id, h.hostname, h.os_name, h.last_user, h.last_seen,
             (SELECT count(*) FROM inventory_packages p WHERE p.host_id = h.id AND p.present) AS packages,
             (SELECT count(DISTINCT s.software_id) FROM v_software_by_host s WHERE s.host_id = h.id) AS software,
             (SELECT count(*) FROM v_policy_violations v WHERE v.host_id = h.id AND v.policy = 'prohibited') AS prohibited,
             (SELECT count(*) FROM v_policy_violations v WHERE v.host_id = h.id AND v.policy = 'restricted') AS restricted,
             (SELECT count(DISTINCT p.fingerprint) FROM inventory_packages p WHERE p.host_id = h.id AND p.present
                 AND NOT EXISTS (SELECT 1 FROM dict_package_map m WHERE m.fingerprint = p.fingerprint)) AS unresolved,
             (SELECT to_jsonb(r) FROM (SELECT r.status, r.received_at, r.added, r.changed, r.removed, r.ai_calls, r.dict_changes
                                        FROM inventory_runs r WHERE r.host_id = h.id ORDER BY r.received_at DESC LIMIT 1) r) AS last_run
      FROM inventory_hosts h) x),
  'kpi', (SELECT jsonb_build_object(
      'hosts', (SELECT count(*) FROM inventory_hosts),
      'packages', (SELECT count(*) FROM inventory_packages WHERE present AND (p_host_id IS NULL OR host_id = p_host_id)),
      'fingerprints', (SELECT count(DISTINCT fingerprint) FROM inventory_packages WHERE present AND (p_host_id IS NULL OR host_id = p_host_id)),
      'software', (SELECT count(*) FROM dict_software),
      'software_on_hosts', (SELECT count(DISTINCT software_id) FROM v_software_by_host WHERE (p_host_id IS NULL OR host_id = p_host_id)),
      'vendors', (SELECT count(*) FROM dict_vendor),
      'rules', (SELECT count(*) FROM dict_rules WHERE enabled),
      'categories', (SELECT count(*) FROM dict_category),
      'mapped_fingerprints', (SELECT count(*) FROM dict_package_map),
      'review_open', (SELECT count(*) FROM review_queue WHERE status = 'open'),
      'violations', (SELECT count(*) FROM v_policy_violations WHERE policy = 'prohibited' AND (p_host_id IS NULL OR host_id = p_host_id)),
      'restricted', (SELECT count(*) FROM v_policy_violations WHERE policy = 'restricted' AND (p_host_id IS NULL OR host_id = p_host_id)),
      'coverage_pct', (SELECT round(100.0 * count(*) FILTER (WHERE software_id IS NOT NULL) / greatest(count(*),1), 1)
                       FROM v_inventory_current WHERE (p_host_id IS NULL OR host_id = p_host_id))
  )),
  'runs', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.received_at DESC), '[]'::jsonb) FROM (
      SELECT ir.id, ir.run_id, ir.host_id, h.hostname, ir.received_at, ir.finished_at, ir.status, ir.packages_total, ir.added, ir.changed, ir.removed,
             ir.fingerprints_total, ir.known_before, ir.resolved_exact, ir.resolved_rule, ir.resolved_ai, ir.unresolved,
             ir.ai_calls, ir.ai_packages, ir.ai_batches_failed, ir.dict_changes, ir.duration_ms
      FROM inventory_runs ir JOIN inventory_hosts h ON h.id = ir.host_id
      WHERE (p_host_id IS NULL OR ir.host_id = p_host_id) ORDER BY ir.received_at DESC LIMIT 12) r),
  'changes', (SELECT jsonb_build_object('run_id', r.run_id, 'received_at', r.received_at,
      'added', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'version', p.version, 'source', p.source, 'publisher', p.publisher) ORDER BY p.name), '[]'::jsonb)
                FROM (SELECT * FROM inventory_packages p WHERE p.host_id = r.host_id AND p.present AND p.first_run_id = r.run_id ORDER BY p.name LIMIT 40) p),
      'removed', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'version', p.version, 'source', p.source, 'publisher', p.publisher) ORDER BY p.name), '[]'::jsonb)
                FROM (SELECT * FROM inventory_packages p WHERE p.host_id = r.host_id AND NOT p.present AND p.last_run_id = r.run_id ORDER BY p.name LIMIT 40) p),
      'changed', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'version', p.version, 'version_prev', p.version_prev, 'source', p.source) ORDER BY p.name), '[]'::jsonb)
                FROM (SELECT * FROM inventory_packages p WHERE p.host_id = r.host_id AND p.present AND p.last_run_id = r.run_id
                      AND p.changed_at IS NOT NULL AND p.changed_at >= r.received_at ORDER BY p.name LIMIT 40) p))
      FROM inventory_runs r WHERE r.host_id = p_host_id ORDER BY r.received_at DESC LIMIT 1),
  'match_types', (SELECT coalesce(jsonb_agg(jsonb_build_object('match_type', mt, 'packages', n) ORDER BY n DESC), '[]'::jsonb) FROM (
      SELECT coalesce(match_type, 'unresolved') mt, count(*) n FROM v_inventory_current WHERE (p_host_id IS NULL OR host_id = p_host_id) GROUP BY 1) x),
  'categories', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name_uk', c.name_uk, 'policy', c.policy,
                        'software', coalesce(s.n_sw,0), 'packages', coalesce(s.n_pk,0)) ORDER BY coalesce(s.n_pk,0) DESC, c.sort_order), '[]'::jsonb)
      FROM dict_category c LEFT JOIN (
          SELECT category_code, count(DISTINCT software_id) n_sw, count(*) n_pk FROM v_inventory_current
          WHERE software_id IS NOT NULL AND (p_host_id IS NULL OR host_id = p_host_id) GROUP BY 1) s
      ON s.category_code = c.code),
  'violations', (SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY v.policy, v.software_name), '[]'::jsonb) FROM (
      SELECT host_id, hostname, software_name, vendor_name, category_code, category_name_uk, policy, package_count, versions
      FROM v_policy_violations WHERE (p_host_id IS NULL OR host_id = p_host_id) ORDER BY policy, software_name LIMIT 80) v),
  'top_products', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.package_count DESC), '[]'::jsonb) FROM (
      SELECT host_id, hostname, software_name, vendor_name, category_code, policy, package_count, component_count, versions, match_types
      FROM v_software_by_host WHERE (p_host_id IS NULL OR host_id = p_host_id) ORDER BY package_count DESC, software_name LIMIT 15) t),
  'review', (SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC), '[]'::jsonb) FROM (
      SELECT id, sample_name, sample_publisher, sample_source, proposed_software, proposed_category, confidence, reason, created_at
      FROM review_queue WHERE status = 'open' ORDER BY created_at DESC LIMIT 25) q),
  'audit', (SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.at DESC), '[]'::jsonb) FROM (
      SELECT id, at, table_name, operation, row_key, actor, run_id,
             coalesce(new_row->>'name', new_row->>'sample_name', old_row->>'name', old_row->>'sample_name', row_key) AS subject,
             new_row->>'match_type' AS match_type, new_row->>'category_code' AS category_code
      FROM audit_log ORDER BY at DESC LIMIT 20) a),
  'rules', (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.hit_count DESC), '[]'::jsonb) FROM (
      SELECT id, name, field, pattern, category_code, software_name, priority, origin, hit_count, last_hit_at
      FROM dict_rules WHERE enabled ORDER BY hit_count DESC, id LIMIT 30) r),
  'sources', (SELECT coalesce(jsonb_agg(jsonb_build_object('source', source, 'packages', n, 'mapped', m) ORDER BY n DESC), '[]'::jsonb) FROM (
      SELECT source, count(*) n, count(*) FILTER (WHERE software_id IS NOT NULL) m FROM v_inventory_current
      WHERE (p_host_id IS NULL OR host_id = p_host_id) GROUP BY 1) s),
  'vendors_top', (SELECT coalesce(jsonb_agg(jsonb_build_object('vendor', vendor_name, 'software', n) ORDER BY n DESC), '[]'::jsonb) FROM (
      SELECT coalesce(vendor_name,'—') vendor_name, count(DISTINCT software_id) n FROM v_software_by_host
      WHERE (p_host_id IS NULL OR host_id = p_host_id) GROUP BY 1 ORDER BY n DESC LIMIT 12) v)
)
$$;

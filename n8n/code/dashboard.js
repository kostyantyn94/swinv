// Рендер HTML-дашборду з одного JSON (swinv_dashboard()). Без зовнішніх залежностей — працює офлайн.
const d = $input.first().json.d || {};
const k = d.kpi || {};
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const num = (n) => (n == null ? '—' : Number(n).toLocaleString('uk-UA'));
const dt = (s) => { if (!s) return '—'; const x = new Date(s); return isNaN(x) ? esc(s) : x.toLocaleString('uk-UA', { hour12: false }); };
const pol = { allowed: ['дозволено', '#1f8a4c'], restricted: ['обмежено', '#c77700'], prohibited: ['заборонено', '#c62828'] };
const mt = { human: ['людина', '#6a1b9a'], rule: ['правило', '#1565c0'], exact: ['точний збіг', '#00838f'], ai: ['AI', '#ef6c00'], seed: ['сід', '#455a64'], unresolved: ['без продукту', '#9e9e9e'] };
const badge = (txt, color) => `<span class="b" style="background:${color}">${esc(txt)}</span>`;
const polBadge = (p) => badge((pol[p] || [p])[0], (pol[p] || ['', '#777'])[1]);
const mtBadge = (m) => badge((mt[m] || [m])[0], (mt[m] || ['', '#777'])[1]);

const runs = d.runs || [];
const runRows = runs.map((r, i) => {
  const zero = r.ai_calls === 0 && r.dict_changes === 0 && r.added === 0 && r.changed === 0 && r.removed === 0 && r.status === 'done';
  return `<tr class="${zero ? 'zero' : ''}">
    <td>${esc(r.id)}</td><td>${dt(r.received_at)}</td><td>${esc(r.hostname)}</td>
    <td class="n">${num(r.packages_total)}</td>
    <td class="n">${num(r.added)} / ${num(r.changed)} / ${num(r.removed)}</td>
    <td class="n">${num(r.fingerprints_total)}</td>
    <td class="n">${num(r.known_before)}</td>
    <td class="n">${num(r.resolved_rule)}</td>
    <td class="n">${num(r.resolved_ai)}</td>
    <td class="n"><b>${num(r.ai_calls)}</b></td>
    <td class="n">${num(r.unresolved)}</td>
    <td class="n"><b>${num(r.dict_changes)}</b></td>
    <td class="n">${r.duration_ms != null ? (r.duration_ms / 1000).toFixed(1) + ' с' : '—'}</td>
    <td>${esc(r.status)}${zero ? ' · <b>0 змін</b>' : ''}</td></tr>`;
}).join('');

const mts = d.match_types || [];
const mtTotal = mts.reduce((a, x) => a + Number(x.packages), 0) || 1;
const mtBars = mts.map(x => `<div class="row"><div class="lbl">${mtBadge(x.match_type)}</div>
  <div class="bar"><div style="width:${(100 * x.packages / mtTotal).toFixed(1)}%;background:${(mt[x.match_type] || ['', '#777'])[1]}"></div></div>
  <div class="val">${num(x.packages)} <small>(${(100 * x.packages / mtTotal).toFixed(0)}%)</small></div></div>`).join('');

const cats = (d.categories || []).filter(c => c.packages > 0 || c.software > 0);
const catMax = Math.max(1, ...cats.map(c => Number(c.packages)));
const catBars = cats.map(c => `<div class="row"><div class="lbl">${esc(c.name_uk)} <small>${esc(c.code)}</small> ${polBadge(c.policy)}</div>
  <div class="bar"><div style="width:${(100 * c.packages / catMax).toFixed(1)}%;background:${(pol[c.policy] || ['', '#777'])[1]}"></div></div>
  <div class="val">${num(c.software)} прод. / ${num(c.packages)} пак.</div></div>`).join('');

const viol = d.violations || [];
const violRows = viol.map(v => `<tr><td>${polBadge(v.policy)}</td><td><b>${esc(v.software_name)}</b></td><td>${esc(v.vendor_name || '—')}</td>
  <td>${esc(v.category_name_uk)}</td><td>${esc(v.hostname)}</td><td class="n">${num(v.package_count)}</td><td>${esc((v.versions || []).slice(0, 3).join(', '))}</td></tr>`).join('');

const top = d.top_products || [];
const topRows = top.map(t => `<tr><td><b>${esc(t.software_name)}</b></td><td>${esc(t.vendor_name || '—')}</td><td>${esc(t.category_code)} ${polBadge(t.policy)}</td>
  <td class="n"><b>${num(t.package_count)}</b> <small>(складових ${num(t.component_count)})</small></td><td>${(t.match_types || []).map(mtBadge).join(' ')}</td>
  <td><small>${esc((t.versions || []).slice(0, 4).join(', '))}</small></td></tr>`).join('');

const rq = d.review || [];
const reasonUk = { low_confidence: 'низька впевненість', unknown_category: 'категорія поза переліком', invalid_output: 'некоректна відповідь AI', ai_unavailable: 'AI недоступний', manual: 'ручне' };
const rqRows = rq.map(q => `<tr><td>${esc(q.id)}</td><td><b>${esc(q.sample_name)}</b><br><small>${esc(q.sample_publisher || '—')} · ${esc(q.sample_source)}</small></td>
  <td>${esc(q.proposed_software || '—')}<br><small>${esc(q.proposed_category || '—')}</small></td><td class="n">${q.confidence != null ? Number(q.confidence).toFixed(2) : '—'}</td>
  <td>${esc(reasonUk[q.reason] || q.reason)}</td><td>${dt(q.created_at)}</td></tr>`).join('');

const au = d.audit || [];
const opUk = { INSERT: 'створено', UPDATE: 'оновлено', DELETE: 'видалено', error: 'помилка' };
const auRows = au.map(a => `<tr><td>${dt(a.at)}</td><td>${esc(a.table_name)}</td><td>${esc(opUk[a.operation] || a.operation)}</td>
  <td>${esc(a.subject)}</td><td>${a.match_type ? mtBadge(a.match_type) : ''} ${esc(a.category_code || '')}</td><td>${esc(a.actor)}</td></tr>`).join('');

const rules = d.rules || [];
const ruleRows = rules.slice(0, 15).map(r => `<tr><td>${esc(r.name)}</td><td><code>${esc(r.field)} ~* ${esc(String(r.pattern).slice(0, 60))}${String(r.pattern).length > 60 ? '…' : ''}</code></td>
  <td>${esc(r.category_code)}</td><td>${esc(r.software_name || '<назва пакета>')}</td><td class="n">${num(r.priority)}</td><td>${esc(r.origin)}</td><td class="n"><b>${num(r.hit_count)}</b></td></tr>`).join('');

const src = d.sources || [];
const srcRows = src.map(s => `<tr><td>${esc(s.source)}</td><td class="n">${num(s.packages)}</td><td class="n">${num(s.mapped)}</td><td class="n">${s.packages ? (100 * s.mapped / s.packages).toFixed(0) : 0}%</td></tr>`).join('');
const vend = (d.vendors_top || []).map(v => `<li>${esc(v.vendor)} <small>— ${num(v.software)}</small></li>`).join('');

const aiShare = (() => { const ai = mts.find(x => x.match_type === 'ai'); return ai ? (100 * ai.packages / mtTotal).toFixed(0) : '0'; })();

const html = `<!doctype html><html lang="uk"><head><meta charset="utf-8"><title>SWInv · Реєстр ПЗ</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{--bg:#f4f6f9;--card:#fff;--ink:#1c2430;--mut:#66717f;--line:#e3e8ee;--acc:#0b5fff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
header{background:#0f1b2d;color:#fff;padding:18px 28px;display:flex;align-items:baseline;gap:18px;flex-wrap:wrap}
header h1{margin:0;font-size:20px;font-weight:600}header small{color:#b8c4d6}header a{color:#9cc3ff;margin-left:auto}
main{padding:20px 28px;max-width:1500px;margin:0 auto}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(138px,1fr));gap:12px;margin-bottom:18px}
.kpi{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.kpi .v{font-size:26px;font-weight:700;letter-spacing:-.5px}.kpi .l{color:var(--mut);font-size:12px}
.kpi.warn .v{color:#c62828}.kpi.ok .v{color:#1f8a4c}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(460px,1fr));gap:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;overflow:auto}
.card.wide{grid-column:1/-1}.card h2{margin:0 0 10px;font-size:15px}.card h2 small{color:var(--mut);font-weight:400;margin-left:8px}
table{border-collapse:collapse;width:100%}th,td{padding:6px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{color:var(--mut);font-weight:600;font-size:12px;white-space:nowrap}td.n,th.n{text-align:right;white-space:nowrap}
tr.zero td{background:#eefaf1}
.b{display:inline-block;color:#fff;border-radius:6px;padding:1px 7px;font-size:11px;font-weight:600;vertical-align:middle}
.row{display:grid;grid-template-columns:minmax(200px,2fr) 3fr 130px;gap:10px;align-items:center;margin:4px 0}
.bar{height:12px;background:#eef1f5;border-radius:6px;overflow:hidden}.bar div{height:100%;border-radius:6px}
.val{text-align:right;white-space:nowrap}.lbl small{color:var(--mut)}
code{font:12px ui-monospace,Consolas,monospace;background:#f1f3f6;padding:1px 4px;border-radius:4px}
.note{color:var(--mut);font-size:12px;margin-top:6px}ul.v{columns:2;margin:0;padding-left:18px}
</style></head><body>
<header><h1>SWInv · Реєстр програмного забезпечення</h1><small>n8n + PostgreSQL + локальна LLM · сформовано ${dt(d.generated_at)}</small>
<a href="/form/inventory/review">Черга перевірки →</a></header>
<main>
<div class="kpis">
 <div class="kpi"><div class="v">${num(k.hosts)}</div><div class="l">хостів</div></div>
 <div class="kpi"><div class="v">${num(k.packages)}</div><div class="l">пакетів (усі джерела)</div></div>
 <div class="kpi"><div class="v">${num(k.software_on_hosts)}</div><div class="l">продуктів на хостах</div></div>
 <div class="kpi ok"><div class="v">${num(k.coverage_pct)}%</div><div class="l">пакетів зіставлено з продуктом</div></div>
 <div class="kpi"><div class="v">${aiShare}%</div><div class="l">частка рішень AI (решта — довідник/правила/людина)</div></div>
 <div class="kpi ${k.violations > 0 ? 'warn' : 'ok'}"><div class="v">${num(k.violations)}</div><div class="l">заборонених продуктів</div></div>
 <div class="kpi"><div class="v">${num(k.restricted)}</div><div class="l">обмежених продуктів</div></div>
 <div class="kpi ${k.review_open > 0 ? 'warn' : 'ok'}"><div class="v">${num(k.review_open)}</div><div class="l">у черзі перевірки</div></div>
 <div class="kpi"><div class="v">${num(k.software)} / ${num(k.vendors)} / ${num(k.rules)}</div><div class="l">довідники: продуктів / вендорів / правил</div></div>
</div>
<div class="grid">
 <div class="card wide"><h2>Запуски інвентаризації <small>доказ прогнозованості: повторний запуск → 0 звернень до AI, 0 змін довідників</small></h2>
  <table><thead><tr><th>#</th><th>Отримано</th><th>Хост</th><th class="n">Пакетів</th><th class="n">нових / змін. / видал.</th><th class="n">Відбитків</th><th class="n">Відомі до запуску</th><th class="n">Правила</th><th class="n">AI</th><th class="n">Звернень до AI</th><th class="n">Без продукту</th><th class="n">Змін довідників</th><th class="n">Час</th><th>Статус</th></tr></thead>
  <tbody>${runRows || '<tr><td colspan="14">Запусків ще не було — запустіть collector/Collect-Inventory.ps1</td></tr>'}</tbody></table></div>
 <div class="card"><h2>Хто прийняв рішення <small>по пакетах</small></h2>${mtBars || '<div class="note">немає даних</div>'}
  <div class="note">Пріоритети запису в довідник: людина 400 › правило 300 › точний збіг 200 › AI 100. Нижчий ніколи не перезаписує вищий.</div></div>
 <div class="card"><h2>Категорії <small>закрита таксономія · політика банку</small></h2>${catBars || '<div class="note">немає даних</div>'}</div>
 <div class="card wide"><h2>Порушення політики <small>заборонене та обмежене ПЗ на хостах</small></h2>
  <table><thead><tr><th>Політика</th><th>Продукт</th><th>Вендор</th><th>Категорія</th><th>Хост</th><th class="n">Пакетів</th><th>Версії</th></tr></thead>
  <tbody>${violRows || '<tr><td colspan="7">Порушень не виявлено</td></tr>'}</tbody></table></div>
 <div class="card wide"><h2>Продукти з найбільшою кількістю пакетів <small>згортання «пакети → продукт»</small></h2>
  <table><thead><tr><th>Продукт</th><th>Вендор</th><th>Категорія</th><th class="n">Пакетів</th><th>Рішення</th><th>Версії</th></tr></thead><tbody>${topRows}</tbody></table></div>
 <div class="card wide"><h2>Черга перевірки людиною <small>${num(k.review_open)} відкритих · <a href="/form/inventory/review">відкрити форму</a></small></h2>
  <table><thead><tr><th>#</th><th>Пакет</th><th>Пропозиція AI</th><th class="n">Впевн.</th><th>Причина</th><th>Створено</th></tr></thead>
  <tbody>${rqRows || '<tr><td colspan="6">Черга порожня</td></tr>'}</tbody></table></div>
 <div class="card"><h2>Правила зіставлення <small>топ за спрацюваннями</small></h2>
  <table><thead><tr><th>Правило</th><th>Умова</th><th>Категорія</th><th>Продукт</th><th class="n">Пріор.</th><th>Джерело</th><th class="n">Спрацювань</th></tr></thead><tbody>${ruleRows}</tbody></table></div>
 <div class="card"><h2>Журнал аудиту довідників <small>останні 20 змін (тригер БД)</small></h2>
  <table><thead><tr><th>Коли</th><th>Таблиця</th><th>Дія</th><th>Об'єкт</th><th>Деталі</th><th>Актор</th></tr></thead><tbody>${auRows || '<tr><td colspan="6">порожньо</td></tr>'}</tbody></table></div>
 <div class="card"><h2>Джерела даних</h2><table><thead><tr><th>Джерело</th><th class="n">Пакетів</th><th class="n">Зіставлено</th><th class="n">%</th></tr></thead><tbody>${srcRows}</tbody></table></div>
 <div class="card"><h2>Вендори <small>за кількістю продуктів</small></h2><ul class="v">${vend}</ul></div>
</div>
<p class="note">SWInv · дані не залишають периметр: класифікацію виконує локальна модель (Ollama, GPU). JSON API: <code>/webhook/inventory/api/dashboard</code></p>
</main></body></html>`;
return [{ json: { html } }];

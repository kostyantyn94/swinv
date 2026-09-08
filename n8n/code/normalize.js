// =====================================================================
//  SWInv — norm_v1: нормалізація пакетів і обчислення відбитка (fingerprint)
//  Цей самий код вставлено у Code-ноду «Нормалізація (norm_v1)» воркфлоу Ingest.
//  Правило: однаковий пакет (без урахування версії/розрядності/локалі) => однаковий відбиток
//  => один і той самий запис довідника => жодного повторного звернення до AI.
// =====================================================================
const NORM_VERSION = 'norm_v1';

// ВАЖЛИВО: список синхронізовано з SQL-функцією swinv_vendor_key (db/schema.sql)
const LEGAL_SUFFIXES = /(^|\s)(inc|incorporated|corp|corporation|co|company|ltd|limited|llc|gmbh|sro|s r o|plc|ag|sa|srl|bv|oy|ab|pte|pty|the|software|team|foundation|technologies|technology|systems|корпорація|корпорация|тов|ооо|компанія|компания)(?=\s|$)/g;

function vendorKey(publisher) {
  if (!publisher) return null;
  let s = String(publisher).normalize('NFKC').toLowerCase()
    .replace(/[™®©,.]/g, ' ')
    .replace(LEGAL_SUFFIXES, ' ')
    .replace(/\s+/g, ' ').trim();
  return s || null;
}

// Очищена назва для показу (зберігає регістр): без версій, розрядності, локалі
function cleanName(name) {
  if (!name) return '';
  let s = String(name).normalize('NFKC')
    .replace(/[™®©]/g, '')
    .replace(/\s*[\(\[]\s*((x64|x86|amd64|arm64|ia64|64[\s-]?bit|32[\s-]?bit|64-розрядн\w*|32-розрядн\w*|64-разрядн\w*|32-разрядн\w*)\s*)+[\)\]]/gi, '')
    .replace(/\s+(x64|x86|amd64|arm64|64[\s-]?bit|32[\s-]?bit)\b/gi, '')
    .replace(/\s+-\s+[a-z]{2}-[a-z]{2}\b/gi, '')                      // " - ru-ru", " - en-us"
    .replace(/\b(version|версія|версия|v\.?)\s*\d[\w.\-]*/gi, '')     // "version 1.2", "v2.3"
    .replace(/\s+\d+(\.\d+){1,4}(\s*\([\w.\-]+\))?\s*$/g, '')        // trailing "26.00", "2025.2.4", "1.2.3 (b45)"
    .replace(/\s+\d+(\.\d+){1,4}\s+/g, ' ')                          // inner "3.12.10 "
    .replace(/\s+-\s*$/g, '')
    .replace(/\s{2,}/g, ' ').trim();
  return s || String(name).trim();
}

function normalizeName(name) {
  return cleanName(name).toLowerCase().replace(/\s+/g, ' ').trim();
}

// Стабільні ідентифікатори мають пріоритет над назвою
function fingerprint(pkg) {
  const src = pkg.source;
  if (src === 'appx') {
    const fam = (pkg.raw && pkg.raw.package_family_name) || String(pkg.source_key).replace(/_[^_]+_[^_]+_[^_]*_/, '_');
    return `appx|${fam.toLowerCase()}`;
  }
  if (src === 'vscode' || src === 'npm' || src === 'pip') return `${src}|${String(pkg.source_key).toLowerCase()}`;
  if (src === 'registry' && /\\Steam App \d+$/i.test(pkg.source_key)) return `steam|${pkg.source_key.split('\\').pop().toLowerCase()}`;
  const n = normalizeName(pkg.name);
  const v = vendorKey(pkg.publisher) || '';
  return `${src}|${n}|${v}`;
}

function normalizePackage(pkg) {
  const name_clean = cleanName(pkg.name);
  const name_normalized = normalizeName(pkg.name);
  const publisher_normalized = vendorKey(pkg.publisher);
  return Object.assign({}, pkg, {
    name_clean,
    name_normalized,
    publisher_normalized,
    fingerprint: fingerprint(pkg),
    norm_version: NORM_VERSION,
  });
}

module.exports = { NORM_VERSION, vendorKey, cleanName, normalizeName, fingerprint, normalizePackage };

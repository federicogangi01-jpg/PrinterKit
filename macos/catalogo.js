// PrinterKit macOS - funzioni sul catalogo in JavaScript for Automation (sempre presente su macOS).
// Uso: osascript -l JavaScript catalogo.js <comando> <argomenti…>
//   valida   <drivers.json>                         -> "ok" oppure "ERRORE: …"
//   marca    <drivers.json> <modello e descrizione> -> id<TAB>nome  (vuoto se nessuna)
//   scegli   <drivers.json> <marca-id> <modello> <versione-macOS> <intel|applesilicon> [linguaggi]
//            -> OK<TAB>id<TAB>famiglia<TAB>versione<TAB>url<TAB>sha256<TAB>tipo<TAB>driverName
//            -> NO<TAB>motivo
//   dominio  <drivers.json> <marca-id> <url>        -> "si" / "no"
//   firmatari <drivers.json> <marca-id>             -> un nome per riga
//   json     <file> <percorso.punti>                -> valore (per ricette e config)
ObjC.import('Foundation');

function leggi(path) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (!s || s.isNil()) throw new Error('file non leggibile: ' + path);
  return JSON.parse(s.js);
}

function cmpVer(a, b) {
  const pa = String(a || '0').split(/[^0-9]+/).filter(Boolean).map(Number);
  const pb = String(b || '0').split(/[^0-9]+/).filter(Boolean).map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] || 0, y = pb[i] || 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

function dominioOk(url, domini) {
  const m = /^https:\/\/([^\/:?#]+)/i.exec(url || '');
  if (!m) return false;
  const h = m[1].toLowerCase().replace(/\.$/, '');
  return domini.some(d => { d = d.toLowerCase(); return h === d || h.endsWith('.' + d); });
}

function valida(c) {
  const err = [];
  if (c.schemaVersion !== 1) err.push('schemaVersion diverso da 1');
  if (!Array.isArray(c.manufacturers) || !c.manufacturers.length) err.push('manufacturers mancante');
  (c.manufacturers || []).forEach(m => {
    ['id', 'name', 'match', 'officialDomains', 'signerNames', 'packages'].forEach(f => { if (m[f] == null) err.push('marca senza ' + f); });
    try { new RegExp(m.match, 'i'); } catch (e) { err.push('regex non valida per ' + m.id); }
    (m.packages || []).forEach(p => {
      ['id', 'driverFamily', 'os', 'osMin', 'arch', 'models', 'sourcePage', 'fileType', 'status'].forEach(f => { if (p[f] == null) err.push(p.id + ' senza ' + f); });
      if (p.status === 'ok' && !p.url) err.push(p.id + ': ok senza url');
      if (p.url && !dominioOk(p.url, m.officialDomains)) err.push(p.id + ': url fuori dai domini ufficiali');
    });
  });
  return err;
}

function scegli(m, model, ver, arch, langs) {
  const nomeArch = arch === 'applesilicon' ? 'Apple Silicon' : 'Intel';
  const perSistema = (m.packages || []).filter(p => p.os === 'macos' && cmpVer(ver, p.osMin) >= 0 &&
    (!p.osMax || cmpVer(ver, p.osMax) <= 0) && (p.arch || []).includes(arch));
  const perModello = p => p.models === '*' || (model && new RegExp(p.models, 'i').test(model));
  let cand = perSistema.filter(p => p.status === 'ok' && perModello(p));
  if (langs.length) {
    const comp = cand.filter(p => !p.language || p.language === 'altro' || langs.includes(p.language));
    if (comp.length) cand = comp;
  }
  if (!cand.length) {
    if (perSistema.some(p => p.status === 'nessun_driver' && perModello(p))) return ['NO', `Il produttore non offre un driver ${m.name} ufficiale per macOS ${ver} ${nomeArch}`];
    return ['NO', `Nessun driver ${m.name} ufficiale per macOS ${ver} ${nomeArch}`];
  }
  // Specifico per modello > universale; poi PostScript (preferito su Mac); poi versione più recente.
  cand.sort((a, b) => ((a.models === '*') - (b.models === '*')) ||
    ((a.language !== 'ps') - (b.language !== 'ps')) || -cmpVer(a.version, b.version));
  const p = cand[0];
  return ['OK', p.id, p.driverFamily, p.version || '', p.url, p.sha256 || '', p.fileType, p.driverName || ''];
}

function run(argv) {
  const cmd = argv[0];
  try {
    if (cmd === 'json') {
      let v = leggi(argv[1]);
      for (const k of (argv[2] || '').split('.').filter(Boolean)) v = v == null ? null : v[k];
      return v == null ? '' : (typeof v === 'object' ? JSON.stringify(v) : String(v));
    }
    const c = leggi(argv[1]);
    if (cmd === 'valida') { const e = valida(c); return e.length ? 'ERRORE: ' + e[0] : 'ok'; }
    if (cmd === 'aggiornato') return c.updatedAt || '';
    if (cmd === 'marca') {
      const t = argv[2] || '';
      const m = t.trim() ? c.manufacturers.find(x => new RegExp(x.match, 'i').test(t)) : null;
      return m ? m.id + '\t' + m.name : '';
    }
    const m = c.manufacturers.find(x => x.id === argv[2]);
    if (!m) return '';
    if (cmd === 'scegli') return scegli(m, argv[3], argv[4], argv[5], (argv[6] || '').split(',').filter(Boolean)).join('\t');
    if (cmd === 'dominio') return dominioOk(argv[3], m.officialDomains) ? 'si' : 'no';
    if (cmd === 'firmatari') return (m.macSignerNames || m.signerNames).join('\n');
    if (cmd === 'nome') return m.name;
  } catch (e) { return 'ERRORE: ' + e.message; }
  return 'ERRORE: comando sconosciuto';
}

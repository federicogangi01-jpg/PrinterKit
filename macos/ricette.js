// PrinterKit macOS - motore delle ricette scanner (stesso formato di windows/modules/RecipeEngine.psm1),
// eseguito con curl. Il certificato autofirmato si accetta (-k) solo per le richieste all'IP della macchina.
// Uso: osascript -l JavaScript ricette.js <kit> <drivers.json> <ip> <modello> <ipMac> <condivisione> <utente> <password> <utenti,…>
ObjC.import('Foundation');
const app = Application.currentApplication();
app.includeStandardAdditions = true;

function leggi(p) { return JSON.parse($.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null).js); }
// Le ricette usano regex .NET: (?i) all'inizio diventa il flag 'i' di JavaScript.
function rx(p, f) { p = String(p); if (p.startsWith('(?i)')) { p = p.slice(4); f = 'i'; } return new RegExp(p, f || ''); }
function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
function sh(cmd) { return app.doShellScript(cmd); }
function elenco(dir) {
  const fm = $.NSFileManager.defaultManager;
  const a = fm.contentsOfDirectoryAtPathError(dir, null);
  return a.isNil() ? [] : ObjC.deepUnwrap(a);
}
function sostituisci(t, v, esc) {
  return String(t).replace(/\{\{\s*([A-Za-z0-9_.]+)\s*\}\}/g, (m, k) => {
    let x = v[k] == null ? '' : String(v[k]);
    if (esc === 'url') x = encodeURIComponent(x);
    if (esc === 'xml') x = x.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
    if (esc === 'json') x = x.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    return x;
  });
}

function http(ctx, step, method, url, body, ctype, headers) {
  const out = ctx.tmp + '/body.txt', hdr = ctx.tmp + '/hdr.txt';
  let c = `curl -s -k --max-time 20 -b ${q(ctx.jar)} -c ${q(ctx.jar)} -o ${q(out)} -D ${q(hdr)} -w '%{http_code}' -X ${method}`;
  if (!step.noRedirect) c += ' -L';
  for (const k in headers) c += ` -H ${q(k + ': ' + headers[k])}`;
  if (body != null) {
    $(body).writeToFileAtomicallyEncodingError(ctx.tmp + '/req2.txt', true, $.NSUTF8StringEncoding, null);
    c += ` -H ${q('Content-Type: ' + ctype)} --data-binary @${q(ctx.tmp + '/req2.txt')}`;
  }
  // -k solo verso l'IP della multifunzione: l'URL viene controllato prima.
  if (!new RegExp('^https?://' + ctx.vars.ip.replace(/\./g, '\\.') + '([:/]|$)').test(url)) throw new Error('richiesta fuori dalla macchina: ' + url);
  const status = parseInt(sh(c + ' ' + q(url)), 10);
  return { status, body: sh(`cat ${q(out)}`), headers: sh(`cat ${q(hdr)}`) };
}

function passi(steps, ctx, dry) {
  let last = null;
  for (const st of steps || []) {
    const label = st.label || st.path;
    if (dry && st.writes) { console.log('[prova] salto: ' + label); continue; }
    let url = sostituisci(st.path || '/', ctx.vars);
    if (!/^https?:\/\//.test(url)) url = ctx.base.replace(/\/$/, '') + url;
    let body = null, ctype = null;
    if (st.form) { body = Object.keys(st.form).map(k => encodeURIComponent(k) + '=' + sostituisci(st.form[k], ctx.vars, 'url')).join('&'); ctype = 'application/x-www-form-urlencoded'; }
    if (st.body) { body = sostituisci(st.body, ctx.vars, st.escape || 'none'); ctype = st.contentType || 'text/plain'; }
    const h = {}; for (const k in (st.headers || {})) h[k] = sostituisci(st.headers[k], ctx.vars);
    const r = http(ctx, st, st.method || 'GET', url, body, ctype, h);
    last = r;
    if (!(st.expectStatus || [200, 301, 302, 303]).includes(r.status)) throw new Error(`passo "${label}": HTTP ${r.status}`);
    if (st.failRegex && rx(sostituisci(st.failRegex, ctx.vars)).test(r.body)) throw new Error(`passo "${label}": errore della macchina`);
    if (st.expectRegex && !rx(sostituisci(st.expectRegex, ctx.vars)).test(r.body)) throw new Error(`passo "${label}": risposta inattesa`);
    for (const k in (st.extract || {})) {
      let src = r.body, spec = st.extract[k];
      if (spec.startsWith('header:')) { const i = spec.indexOf(':', 7); src = r.headers; spec = spec.slice(i + 1); }
      const m = rx(spec, 'i').exec(src);
      if (m) ctx.vars[k] = m[1]; else if (!st.extractOptional) throw new Error(`passo "${label}": valore ${k} non trovato`);
    }
  }
  return last;
}

function run(argv) {
  const [kit, cat, ip, model, hostIp, share, user, password, usersText] = argv;
  const c = leggi(cat);
  const man = c.manufacturers.find(m => new RegExp(m.match, 'i').test(model));
  if (!man) return 'Marca non riconosciuta: rubrica da compilare a mano';
  const dir = kit + '/scanner-ricette/' + man.id;
  const tmp = sh('mktemp -d /tmp/pkricetta.XXXXXX');
  for (const f of elenco(dir).filter(f => f.endsWith('.json'))) {
    const r = leggi(dir + '/' + f);
    if (!rx(r.modelMatch || '.', 'i').test(model)) continue;
    let base = null;
    const ctx = { tmp, jar: tmp + '/cookies.txt', vars: { ip, adminUser: (r.defaultAdmin || {}).user || 'admin', adminPassword: (r.defaultAdmin || {}).password || '' } };
    for (const s of r.schemes || ['https', 'http']) {
      try {
        ctx.base = s + '://' + ip;
        const fp = r.fingerprint || {};
        const resp = http(ctx, {}, 'GET', ctx.base + (fp.path || '/'), null, null, {});
        if (!fp.regex || rx(fp.regex).test(resp.body)) { base = ctx.base; break; }
      } catch (e) { }
    }
    if (!base) continue;
    ctx.base = base;
    try { passi(r.login, ctx); }
    catch (e) {
      // Una sola prova con la password di fabbrica, poi la chiede al tecnico.
      const p = app.displayDialog('Password amministratore della multifunzione (' + ctx.vars.adminUser + '):', { defaultAnswer: '', hiddenAnswer: true, withTitle: 'PrinterKit' }).textReturned;
      ctx.vars.adminPassword = p; sh(`rm -f ${q(ctx.jar)}`);
      passi(r.login, ctx);
    }
    if (!r.validata) {
      const b = app.displayDialog(`La ricetta "${r.id}" non è ancora collaudata su una macchina reale. Procedo con la scrittura delle voci?`, { buttons: ['No', 'Sì'], defaultButton: 'Sì', withTitle: 'PrinterKit' }).buttonReturned;
      if (b !== 'Sì') return 'Scrittura annullata dal tecnico';
    }
    if (r.backup) { try { passi([r.backup], ctx); } catch (e) { console.log('backup rubrica non riuscito: ' + e.message); } }
    let i = 0;
    for (const u of usersText.split(',').map(s => s.trim()).filter(Boolean)) {
      i++;
      const rel = share + '\\' + u;
      const fmt = r.pathFormat || 'unc';
      Object.assign(ctx.vars, {
        index: i, name: u, host: hostIp, share, folder: u, user, password, domain: '', format: 'PDF',
        path: fmt === 'unc' ? '\\\\' + hostIp + '\\' + rel : fmt === 'split-slash' ? '/' + rel.replace(/\\/g, '/') : rel,
        uncPath: '\\\\' + hostIp + '\\' + rel
      });
      passi(r.addEntry, ctx);
      if (r.verify) passi(r.verify, ctx);
      console.log('Voce di rubrica "' + u + '" creata');
    }
    if (r.logout) { try { passi([r.logout], ctx); } catch (e) { } }
    return 'Multifunzione configurata con la ricetta ' + r.id;
  }
  sh(`open ${q('http://' + ip)}`);
  return 'Ricetta non disponibile per questo modello: aperta la pagina web della macchina';
}

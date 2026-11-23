// zen_session_title.js <sessionID> — imprime o titulo da sessao (ou vazio)
const { DatabaseSync } = require('node:sqlite');
const id = process.argv[2];
if (!id) { console.log(''); process.exit(0); }
try {
  const db = new DatabaseSync(process.env.USERPROFILE.replace(/\\/g, '/') + '/.local/share/opencode/opencode.db', { readOnly: true });
  const r = db.prepare('select title from session_v2 where id = ?').get(id);
  console.log(r ? (r.title || '') : '');
} catch (e) {
  console.log('');
}

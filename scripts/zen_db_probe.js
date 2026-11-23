const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('C:/Users/SENAI/.local/share/opencode/opencode.db', { readOnly: true });
const rows = db.prepare("select idle_outcome, resume_attempts, count(*) n from session_v2 group by idle_outcome, resume_attempts order by n desc limit 20").all();
for (const r of rows) console.log(JSON.stringify(r));
console.log('\n--- sessoes recentes ---');
const s = db.prepare("select id, title, model, resume_attempts, idle_outcome, time_updated from session_v2 order by time_updated desc limit 8").all();
for (const r of s) console.log(r.id, '|', (r.title||'').slice(0,40), '| resume:', r.resume_attempts, '| idle:', r.idle_outcome, '|', new Date(r.time_updated).toISOString());

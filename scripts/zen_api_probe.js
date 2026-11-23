const fs = require('fs');
const spec = JSON.parse(fs.readFileSync('C:/Users/SENAI/zen_openapi.json', 'utf8'));
for (const p of ['/api/session', '/api/session/{sessionID}/prompt', '/api/session/{sessionID}/synthetic']) {
  const item = spec.paths[p];
  if (!item) continue;
  for (const m of Object.keys(item)) {
    const op = item[m];
    console.log('\n=== ' + m.toUpperCase() + ' ' + p + ' (' + (op.operationId || '') + ')');
    console.log('  ' + (op.description || ''));
    const sch = op.requestBody && op.requestBody.content && op.requestBody.content['application/json'] && op.requestBody.content['application/json'].schema;
    if (sch) console.log('  body: ' + JSON.stringify(sch).slice(0, 900));
  }
}

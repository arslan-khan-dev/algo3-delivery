// Sample migration, run by the deployer as RELEASE_COMMAND before the switch.
const fs = require('node:fs');
const target = Number(process.env.SCHEMA_TARGET || 2);
fs.writeFileSync('/data/schema.json', JSON.stringify({ schema: target }));
console.log(`migrated to schema ${target}`);

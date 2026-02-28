#!/usr/bin/env node
const { getEnvDiagnostics } = require('./billing');

const diagnostics = getEnvDiagnostics();

if (diagnostics.ok) {
  console.log('✅ Billing env preflight passed');
  process.exit(0);
}

console.error('❌ Billing env preflight failed:');
for (const issue of diagnostics.issues) {
  console.error(`- ${issue}`);
}
process.exit(1);

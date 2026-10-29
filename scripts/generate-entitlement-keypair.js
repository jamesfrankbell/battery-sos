#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');

const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const der = publicKey.export({ type: 'spki', format: 'der' });
const raw = der.subarray(der.length - 32).toString('base64');
const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }).trim();

console.log('Public key (paste into EntitlementSigner.publicKeyBase64 in mac/BatteryEmergencyOverlay.swift):');
console.log(raw);
console.log('');
console.log('Private key (set ENTITLEMENT_SIGNING_PRIVATE_KEY on Render only; do not commit it).');
console.log('A single-line env value may use \\n in place of newlines.');
console.log('');
console.log(pem);

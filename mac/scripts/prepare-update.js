#!/usr/bin/env node
'use strict';
// Local preparation only: never writes website/appcast.xml or publishes files.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

function verifyArchive(bytes, signature, publicKey) {
  const raw = Buffer.from(publicKey, 'base64');
  const sig = Buffer.from(signature, 'base64');
  if (raw.length !== 32 || sig.length !== 64) return false;
  const key = crypto.createPublicKey({ key: Buffer.concat([
    Buffer.from('302a300506032b6570032100', 'hex'), raw,
  ]), format: 'der', type: 'spki' });
  return crypto.verify(null, bytes, key, sig);
}
const xml = value => String(value).replace(/[&<>"']/g, c => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;',
})[c]);
function appcast({ version, build, minimumOS, length, signature }) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel><title>Battery SOS</title><item>
    <title>${xml(version)}</title>
    <sparkle:version>${xml(build)}</sparkle:version>
    <sparkle:shortVersionString>${xml(version)}</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>${xml(minimumOS)}</sparkle:minimumSystemVersion>
    <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
    <enclosure url="https://batterysos.app/downloads/battery-sos-macos.dmg" length="${length}" type="application/octet-stream" sparkle:edSignature="${xml(signature)}"/>
  </item></channel>
</rss>
`;
}
function command(program, args) {
  const result = spawnSync(program, args, { encoding: 'utf8', timeout: 15000 });
  return { status: result.error ? 'blocked' : result.status === 0 ? 'passed' : 'failed',
    exitCode: result.status, output: ((result.stdout || '') + (result.stderr || '') +
      (result.error ? result.error.message : '')).trim() };
}
function bundleDigest(directory) {
  const digest = crypto.createHash('sha256');
  function walk(dir, relative = '') {
    for (const name of fs.readdirSync(dir).sort()) {
      const full = path.join(dir, name), rel = path.join(relative, name), stat = fs.lstatSync(full);
      digest.update(rel + '\0');
      if (stat.isSymbolicLink()) digest.update('link\0' + fs.readlinkSync(full));
      else if (stat.isDirectory()) { digest.update('directory\0'); walk(full, rel); }
      else { digest.update('file\0'); digest.update(fs.readFileSync(full)); }
    }
  }
  walk(directory); return digest.digest('hex');
}
function inspectPayload(dmg, app) {
  const mount = fs.mkdtempSync(path.join(os.tmpdir(), 'battery-sos-readonly-'));
  let result;
  try {
    const attach = command('/usr/bin/hdiutil', ['attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mount, dmg]);
    if (attach.status !== 'passed') result = attach;
    else {
      const embedded = path.join(mount, path.basename(app));
      const matches = fs.existsSync(embedded) && bundleDigest(embedded) === bundleDigest(app);
      result = { status: matches ? 'passed' : 'failed', output: matches ? 'Complete bundle bytes and symlink targets match the read-only DMG payload.' : 'DMG payload differs from supplied app.' };
    }
  } catch (error) { result = { status: 'blocked', output: error.message }; }
  finally {
    const detached = command('/usr/bin/hdiutil', ['detach', mount]);
    if (detached.status === 'passed') fs.rmdirSync(mount);
    else if (result?.status === 'passed') result = { status: 'blocked', output: detached.output };
  }
  return result;
}
function main(args) {
  if (args.length < 3 || args.length > 4) {
    throw new Error('Usage: node prepare-update.js APP DMG NEW_OUTPUT_DIRECTORY [ED25519_SIGNATURE]');
  }
  const [appArg, dmgArg, outArg, signature] = args;
  const app = path.resolve(appArg), dmg = path.resolve(dmgArg), out = path.resolve(outArg);
  if (fs.existsSync(out)) throw new Error('Output directory must be new; existing evidence is never overwritten.');
  const plistRead = command('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')]);
  if (plistRead.status !== 'passed') throw new Error(plistRead.output);
  const plist = JSON.parse(plistRead.output);
  const bytes = fs.readFileSync(dmg);
  const executable = path.join(app, 'Contents/MacOS', plist.CFBundleExecutable);
  const checks = {
    appSignature: command('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', app]),
    dmgSignature: command('/usr/bin/codesign', ['--verify', '--verbose=2', dmg]),
    notarizationTicket: command('/usr/bin/xcrun', ['stapler', 'validate', dmg]),
    architecture: command('/usr/bin/lipo', ['-archs', executable]),
    deploymentTarget: command('/usr/bin/otool', ['-l', executable]),
    signer: command('/usr/bin/codesign', ['-d', '--verbose=4', app]),
  };
  const targetMatch = checks.deploymentTarget.output.match(/\bminos\s+([\d.]+)/);
  const sameVersion = (a, b) => String(a).replace(/(?:\.0)+$/, '') === String(b).replace(/(?:\.0)+$/, '');
  checks.targetMatchesPlist = { status: targetMatch && sameVersion(targetMatch[1], plist.LSMinimumSystemVersion) ? 'passed' : 'failed',
    output: `binary=${targetMatch?.[1] || 'unknown'} plist=${plist.LSMinimumSystemVersion}` };
  checks.arm64 = { status: checks.architecture.output === 'arm64' ? 'passed' : 'failed' };
  const executableBytes = fs.readFileSync(executable);
  checks.billingEndpoint = { status: executableBytes.includes(Buffer.from('https://pay.batterysos.app')) &&
    !executableBytes.includes(Buffer.from('http://127.0.0.1:8787')) ? 'passed' : 'failed' };
  checks.sparkleSignature = { status: signature ? (verifyArchive(bytes, signature, plist.SUPublicEDKey) ? 'passed' : 'failed') : 'blocked',
    output: signature ? 'Verified against the public key embedded in the app.' : 'Signature for final stapled DMG required.' };
  checks.dmgPayloadIdentity = inspectPayload(dmg, app);
  checks.secureTimestamp = { status: /\bTimestamp=/.test(checks.signer.output) ? 'passed' : 'blocked',
    output: 'Native signer inspection must identify the secure timestamp.' };
  checks.developerID = { status: /Authority=Developer ID Application:/.test(checks.signer.output) ? 'passed' : 'blocked',
    output: 'Ad-hoc signatures are suitable for local inspection, not distribution.' };
  const provenancePath = path.join(app, 'Contents/Resources/BuildProvenance.plist');
  let buildProvenance = null;
  if (fs.existsSync(provenancePath)) {
    const read = command('/usr/bin/plutil', ['-convert', 'json', '-o', '-', provenancePath]);
    if (read.status === 'passed') buildProvenance = JSON.parse(read.output);
  }
  checks.buildProvenance = { status: buildProvenance?.BuildNumber === plist.CFBundleVersion ? 'passed' : 'blocked',
    output: 'Embedded provenance records the source at compilation; inspection-time Git state is separate.' };
  const repo = path.resolve(__dirname, '../..');
  const sourceRevision = command('git', ['-C', repo, 'rev-parse', 'HEAD']);
  const sourceWorktree = command('git', ['-C', repo, 'status', '--short']);
  const manifest = {
    checkedAt: new Date().toISOString(), app, dmg,
    version: plist.CFBundleShortVersionString, build: plist.CFBundleVersion,
    minimumOS: plist.LSMinimumSystemVersion,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'), length: bytes.length,
    executableSHA256: crypto.createHash('sha256').update(executableBytes).digest('hex'),
    sourceRevision: sourceRevision.output, sourceWorktree: sourceWorktree.output,
    buildProvenance,
    checks, releaseAccepted: Object.values(checks).every(c => c.status === 'passed'),
  };
  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, 'release-manifest.json'), JSON.stringify(manifest, null, 2) + '\n', { flag: 'wx' });
  fs.writeFileSync(path.join(out, 'battery-sos-macos.dmg.sha256'), `${manifest.sha256}  battery-sos-macos.dmg\n`, { flag: 'wx' });
  // Metadata can be staged only after cryptographic signature verification.
  // The manifest still requires payload and native trust checks before publishing.
  if (checks.sparkleSignature.status === 'passed') {
    fs.writeFileSync(path.join(out, 'appcast.xml'), appcast({ ...manifest, signature }), { flag: 'wx' });
  }
  console.log(JSON.stringify({ output: out, version: manifest.version, build: manifest.build,
    sha256: manifest.sha256, checks: Object.fromEntries(Object.entries(checks).map(([k,v]) => [k,v.status])),
    releaseAccepted: manifest.releaseAccepted }, null, 2));
  process.exitCode = Object.values(checks).every(c => c.status === 'passed') ? 0 : 2;
}
module.exports = { verifyArchive, appcast };
if (require.main === module) {
  try { main(process.argv.slice(2)); } catch (error) { console.error(error.message); process.exitCode = 1; }
}

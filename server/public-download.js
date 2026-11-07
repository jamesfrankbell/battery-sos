'use strict';

// Archived installer that the public route served until PR #5 deleted the file.
// Commit 68b7bea, blob 2720b40037fdb5d1364ab3fb5cf3893b90d0b3d1.
// sha256 c7ac6df78b80acdf92ad0b6990b7f550cc28292cf444c26bcd32750759608c60
// size 1429342. Checksum blob 1396a86dd64c297869100ad2b5c3a46b38ba14ea.
//
// Static inspection on 2026-11-07, after sha256 of the git blob matched:
// dmg2img 1.6.7 decompressed the UDIF image (koly trailer at offset 1428830).
// The decompressed image contains the Swift string http://127.0.0.1:8787 next
// to BATTERY_SOS_BILLING_URL and MonetizationManager. It does not contain
// pay.batterysos.app. Info.plist inside the image says CFBundleShortVersionString
// 1.0.0 and CFBundleVersion 202603110225. The image was not executed.
//
// The route must not send this file. Customers would get an installer whose
// compiled billing default is their own loopback.
const LAST_PUBLIC_RELEASE_COMMIT = '68b7bea5f8ec3ec4a4fa12b7712d0a635b7e77a4';
const LAST_PUBLIC_DMG_SHA256 = 'c7ac6df78b80acdf92ad0b6990b7f550cc28292cf444c26bcd32750759608c60';
const LAST_PUBLIC_DMG_BYTES = 1429342;
const COMPILED_BILLING_URL = 'http://127.0.0.1:8787';

function publicDownloadResponse(pathname) {
  if (pathname !== '/downloads/battery-sos-macos.dmg' && pathname !== '/downloads/battery-sos-macos.dmg.sha256') {
    return null;
  }
  return {
    status: 404,
    body: {
      error: 'Download withheld.',
      sha256: LAST_PUBLIC_DMG_SHA256,
      bytes: LAST_PUBLIC_DMG_BYTES,
      containedBuild: '202603110225',
      compiledBillingURL: COMPILED_BILLING_URL,
    },
  };
}

module.exports = {
  COMPILED_BILLING_URL,
  LAST_PUBLIC_DMG_BYTES,
  LAST_PUBLIC_DMG_SHA256,
  LAST_PUBLIC_RELEASE_COMMIT,
  publicDownloadResponse,
};

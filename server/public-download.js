'use strict';

// The public download route used to read mac/dist/battery-sos-macos.dmg out of
// the deploy. PR #5 removed that committed file and nothing was put in its
// place, so the route 404s. These URLs are the immutable Git blobs of the last
// file main actually shipped at that path (commit 68b7bea, blob 2720b400,
// 1,429,342 bytes). They are not a new build.
//
// Measured 2026-11-07 from this repo and from raw.githubusercontent.com:
//   HTTP 200, content-length 1429342
//   sha256 c7ac6df78b80acdf92ad0b6990b7f550cc28292cf444c26bcd32750759608c60
//   byte-identical to `git cat-file -p 2720b40037fdb5d1364ab3fb5cf3893b90d0b3d1`
// The committed checksum file at that same commit is that hash and a newline.
//
// James mounted this DMG read-only on 2026-11-07. The app inside is 1.0.0
// build 202603110225, bundle com.jamesbell.battery-sos, macOS 13+, arm64.
// codesign --verify --strict passed. Gatekeeper accepted a notarized
// Developer ID for JAMES FRANK BELL (9JNKPQCLGG), and the DMG ticket was
// stapled. The new entitlement public key is not in that app. It is the old
// licensing client. The published sparkle:edSignature verifies only the
// older 1,362,061-byte archive (build 202603061320, commit 3f1f49d) and
// returns false for these 1,429,342 bytes. The feed must not reuse it.
const LAST_PUBLIC_RELEASE_COMMIT = '68b7bea5f8ec3ec4a4fa12b7712d0a635b7e77a4';
const LAST_PUBLIC_DMG_SHA256 = 'c7ac6df78b80acdf92ad0b6990b7f550cc28292cf444c26bcd32750759608c60';
const LAST_PUBLIC_DMG_BYTES = 1429342;

function historicalRawUrl(filename) {
  return `https://raw.githubusercontent.com/jamesfrankbell/battery-sos/${LAST_PUBLIC_RELEASE_COMMIT}/mac/dist/${filename}`;
}

const LAST_PUBLIC_DMG_URL = historicalRawUrl('battery-sos-macos.dmg');
const LAST_PUBLIC_DMG_SHA256_URL = historicalRawUrl('battery-sos-macos.dmg.sha256');

function publicDownloadRedirect(pathname) {
  if (pathname === '/downloads/battery-sos-macos.dmg') {
    return {
      location: LAST_PUBLIC_DMG_URL,
      sha256: LAST_PUBLIC_DMG_SHA256,
      bytes: LAST_PUBLIC_DMG_BYTES,
    };
  }
  if (pathname === '/downloads/battery-sos-macos.dmg.sha256') {
    return { location: LAST_PUBLIC_DMG_SHA256_URL };
  }
  return null;
}

module.exports = {
  LAST_PUBLIC_DMG_BYTES,
  LAST_PUBLIC_DMG_SHA256,
  LAST_PUBLIC_DMG_SHA256_URL,
  LAST_PUBLIC_DMG_URL,
  LAST_PUBLIC_RELEASE_COMMIT,
  publicDownloadRedirect,
};

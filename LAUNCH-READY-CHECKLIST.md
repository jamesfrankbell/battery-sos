# Battery SOS release acceptance

Updated October 2, 2026 UTC. This is a gate checklist, not a claim of public
readiness. Preserve the separate recovery record and prior build evidence.

## Local code checks

- Explicit arm64/macOS 13 compilation, embedded source provenance and unique build output.
- Isolated billing tests: paid/unpaid/delayed sessions, activation, invalid keys,
  duplicate/stale/forged webhooks, failed writes, corruption and process restart.
- Battery simulations: threshold boundaries, dismissal/recovery, AC transitions,
  no-battery preview, repeated samples, sensor interruption and sleep/wake.
- Theme persistence, Free/Pro gating, Vitals labeling and activation error handling.
- Release metadata tests: verified archive signature, current build and actual length.

These checks must pass on the final source snapshot. Test evidence belongs to its
specific revision, worktree hashes and build; older passes do not accept a new build.

## Required exact-build interactive checks — not yet run

- Fresh install and update from the existing public release, preserving settings/license.
- All six themes: readable layout, Escape/close, repeated preview, mute and stopped audio.
- Real MacBook battery boundary, AC connection, dismissal, recovery and sleep/wake.
- Multiple displays/Spaces and start-at-login, quit and relaunch behavior.
- Native app activation after controlled test-mode payment; cancellation and delayed payment.
- macOS 13 runtime if that minimum is retained. Intel support is not established.

## Billing/service gates — deployment not authorized by local work

- Persistent billing volume configured and verified on the intended deployed revision.
- Existing license records backed up and recoverable; one server process owns the JSON store.
- Stripe event delivery enabled for `checkout.session.completed` and
  `checkout.session.async_payment_succeeded`; only paid sessions issue keys.
- Server clock accurate enough for the five-minute webhook tolerance.
- Recovery authorized by existing admin bearer header; anonymous email lookup denied.
- Self-service recovery sends a one-time link or code and reveals the existing key only after that proof. It is not deployed. Production delivery needs `BILLING_EMAIL_PROVIDER=http` before customers can receive it. The console provider is for development and tests.

Do not put credentials in this checklist, command output, URLs or screenshots.
Account/agreement status is tracked separately; no account change is implied here.

## Artifact and publication gates

- Pin source revision/worktree hashes, version/build, architecture and deployment target.
- Existing approved Developer ID signing, secure timestamp and native signature verification.
- Notarization acceptance and valid stapled ticket for the exact final DMG.
- Read-only payload comparison between that DMG and its verified app bundle.
- Calculate final SHA256 and byte length after all artifact changes.
- Verify Sparkle signature against the app's embedded public key; prepare local appcast.
- Appcast build, length, URL and signature must describe the final downloadable bytes.
- Explicit approval for any new notarization submission, deployment or publication.
- After approved publication, fetch and verify actual download/update behavior.

The old feed describes build 202603061320; it must not be silently paired with
a newer DMG. Do not reuse hashes, signatures or notarization results from another build.

## James's remaining decisions

- Confirm real Support, Privacy and Terms destinations before public release.
- Approve the final theme/audio/flashing experience after viewing the exact build.
- Confirm the recovery email provider and its URL before any server deploy that should deliver self-service recovery. The admin path remains available.
- Agree on hardware/OS coverage or explicitly waive uncovered targets with consequences.
- Handle account/legal/certificate decisions and release authorization separately.

The $1 price and Free/Pro theme entitlements stay as they are. The emergency threshold still defaults to 1%. A license is active on one Mac, with 3 transfers in a rolling year, bound to a SHA-256 of the hardware UUID. Existing Mac-name activations migrate when that Mac's name still matches. Calm alerts, per-theme volume, the welcome window, the app icon, and the template menu-bar item are in the 1.0.1 app. Publication still requires James's approval. A blocked or unrun required check does not count as a pass.

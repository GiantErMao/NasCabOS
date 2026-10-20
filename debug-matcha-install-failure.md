# Debug Session: matcha-install-failure
- **Status**: [OPEN]
- **Issue**: Matcha Baker model installation fails after download.
- **Debug Server**: Not required; device UI and ADB provide the pre-fix runtime evidence.
- **Log File**: ADB logcat and UIAutomator capture

## Reproduction Steps
1. Install Android client version 1.2.7+2039.
2. Open a TXT book and the speech panel.
3. Start downloading the Matcha Baker local model.
4. Wait for download verification.

## Hypotheses & Verification
| ID | Hypothesis | Likelihood | Effort | Evidence |
|----|------------|------------|--------|----------|
| A | Downloaded artifact length or checksum no longer matches the manifest | High | Low | Confirmed: upstream asset is now 75,480,421 bytes with SHA-256 `fc41...fe56` |
| B | Extracted archive structure differs from required files | Medium | Low | Rejected for this run; extraction was not reached |
| C | Staging rename or legacy Kokoro cleanup failed | Low | Low | Rejected for this run; verification failed first |
| D | Device has insufficient temporary storage | Low | Low | Rejected; `/data` has 180 GB free |
| E | User interruption was surfaced as installation failure | Low | Low | Rejected; explicit length validation error |

## Log Evidence
- Pre-fix UI: `模型安装失败 / matcha-icefall-zh-baker.tar.bz2 has an invalid length`
- Device storage: 180 GB available.
- Installed app: 1.2.7+2039.
- GitHub asset updated at `2026-10-08T10:56:26Z`.
- Current asset: 75,480,421 bytes, SHA-256 `fc41b5115c45ffab7f46e1a5a0fcefd15b2698e32ca5d080dde7a5e7caa2fe56`.
- Old manifest: 75,463,442 bytes, SHA-256 `20de2ec034b55562609d6362771c934905dfe11d0f41ec103d593427ad9a7efb`.
- Downloaded archive contains every required Matcha file; Vocos metadata is unchanged.

## Verification Conclusion
The upstream Matcha archive was replaced after the original manifest was created. Keep strict length and SHA-256 verification, but update both trusted values to the current GitHub Release metadata. Post-fix device verification remains pending.

## 2026-10-20 follow-up
- Reproduced on ADB device e6fc7cb7, installed version 1.2.7+2066.
- UI still reports acoustic archive length mismatch.
- Official download now returns 75,480,460 bytes (Last-Modified: 2026-10-15), replacing the previously verified archive again.
- Downloaded the full archive and computed SHA-256: `c3e1889c1b745180445daba6c1f51fb4aeceaff8500da425da6c5ff80e8620c5`.
- Checked archive listing: all required acoustic files remain present. Updated manifest and its regression test; all 5 manifest tests passed.
- Device uses release certificate SHA-256 `6ef8c8451b9e93460b2283688833ce72cb2a9024ebba66807dc610494850be2d`. Matching signing key is unavailable on this host; device upgrade verification remains pending.

## Bundled model implementation
- Per user request, both verified model artifacts now live under `flutter_client/assets/tts/` and are declared in pubspec.yaml.
- Removed runtime HTTP model downloads, range resume, and download/cancel/delete controls. The speech panel starts local asset verification and extraction automatically, displaying its state immediately.
- Valid existing installations are reused; failed installations can retry from assets without network access. Shared installation futures protect overlapping readers.
- Retained integrity verification and source license information.
- 17 tests passed, including real bundled archive extraction, concurrent initialization, reuse, corrupt asset rejection, and retry.
- Regular release APK build succeeds (version 1.2.7+2067, approximately 440.6 MB). Verified both model assets inside the APK against their pinned sizes and SHA-256 digests.
- After the original app was removed from the device, signed with the local Android debug key, installed successfully on ADB device e6fc7cb7, confirmed version 1.2.7+2067, and launched MainActivity. On-device speech playback verification remains pending.

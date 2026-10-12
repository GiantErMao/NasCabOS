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

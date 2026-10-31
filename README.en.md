# VoiceStudio for Android (Unofficial Port · Incomplete)

[简体中文](README.md) | **English**

An Android port of the open-source voice workstation [VoiceStudio](https://github.com/debpalash/VoiceStudio) (AGPL-3.0): **a self-contained APK intended to work after installation, without Termux, root, or a PC**.

<p align="center">
  <a href="https://afdian.com/a/123xiaole">
    <img src="https://img.shields.io/badge/Afdian-Support%20the%20author-946CE6?style=for-the-badge" alt="Sponsor on Afdian">
  </a>
</p>
<p align="center"><strong>Voluntarily support project maintenance</strong> · <a href="SPONSOR.en.md">Sponsorship details</a> · <a href="SPONSOR.md">简体中文</a></p>

> ⚠️ **Important: this is an incomplete project.**
> The core path has been demonstrated on a real device (environment bootstrap → Python backend → usable full interface), but known issues remain. During repository cleanup, **the Java source code for the native Android shell was lost**. This repository contains Android adaptation files and engineering records, not the complete native project. See “Current Status” and “Missing Components” below.

---

## Architecture

```
APK (1.2 GB, self-contained)
├── WebView ──── loads the upstream frontend (assets/webui)
├── Native shell :3900 ── static assets + startup gate + fallback stubs + reverse proxy
├── proot (renamed to libvsproot.so under lib/arm64-v8a/)
└── Ubuntu 24.04 rootfs (tar.gz in assets, extracted on first launch)
         └── uvicorn :3901 ← actual VoiceStudio Python backend
```

Several engineering details required substantial debugging:

- **The recorded test installation downloaded zero bytes.** The test package record contained 338 `.deb` packages and 295 Python wheels; the installation log counted **0** `Downloading` entries and the process took about 15–20 minutes. This is not an offline guarantee for every installation environment: if the `/root/.vs-bootstrap/base` marker is missing, `bootstrap.sh` runs `apt-get update`; incomplete caches may cause the host to wait for downloads or fall back to network installation. Actual offline behavior depends on whether the APK/rootfs contains the complete cache and preconfigured state.
- **Startup gate.** The backend must import PyTorch, and a cold start can take 1–3 minutes. During that time the frontend may request routes that are not ready and fail inside its error boundary; that error page does not yet provide a return path. The frontend is therefore withheld until the engine is ready, with a real progress page shown first.
- **API warm-up.** A successful `/health` response does not mean the app is ready: the first `/engines` request took 31 seconds and `/setup/preflight` took 13 seconds (later requests took 1.4 seconds and 0.45 seconds). The loading page pre-requests the 20 APIs needed by the frontend's initial screen so the interface is usable when displayed.
- **A `/proc` access failure on the tested firmware.** In the only verified V2463A / Android 16 firmware and app context for this project, the backend received `PermissionError` when reading `/proc/stat`, causing psutil initialization to fail. This is a device/ROM/access-context-specific observation; it must not be generalized into a claim that all ordinary apps on all Android 16 devices are denied access to `/proc/stat`. The implementation probes actual file access at runtime and uses a proot-bound substitute only when the target file is confirmed unreadable.

---

## Current Status

**Demonstrated working**

- The complete first-install path—environment bootstrap, Python backend startup, and usable interface—ran on a physical device.
- Backend logs confirmed: `Deferred startup complete — all routes live.`
- The model package (OmniVoice, 3.27 GB / 13 files) can be downloaded into the app-private directory.

**Known issues**

| Issue | Details |
|---|---|
| Backend download worker may hang | A task can remain at `downloading 0 B` and the Cancel button may not work. Cancellation is best-effort and waits for a retry boundary; a hung worker may never reach one. Restarting the app clears it. **Root cause not identified.** |
| Cold start takes 50–120 seconds | Mostly due to PyTorch import. This has not been eliminated; the loading page displays progress. |
| First `/engines` request takes 31 seconds | Warm-up masks the delay but does not solve the underlying issue. |
| CPU only | No GPU acceleration; TTS synthesis is slow. |

**Test environment**

| Item | Value |
|---|---|
| Device | vivo V2463A (Snapdragon 8 Elite / SM8750, 8 cores, 14 GiB RAM) |
| System | Android 16 (API 36), arm64-v8a, 1440×3168 / 640 dpi |
| First installation | About 15–20 minutes; the recorded test completed with zero downloads |
| Subsequent cold start | About 50–120 seconds |
| Installed footprint | Root filesystem about 4.8 GB |

**Compatibility boundary:** The project has only been verified on the single V2463A device and its current firmware described above. The Android version number alone cannot predict `/proc` access permissions. SELinux policy, kernel configuration, ROM modifications, app UID/targetSdk, and WebView implementation may all affect behavior. Other devices and firmware builds are unverified; no compatibility guarantee is made.

---

## Missing Components (Important)

During repository cleanup, **the Java source code for the native shell was accidentally deleted and no backup exists**. The repository therefore does not contain:

- Java sources such as `MainActivity`, `VsApi`, `LocalServer`, `BackendLauncher`, `RuntimeInstaller`, `ParallelFetcher`, `ModelFetcher`, and `ProcShim`;
- APK build-pipeline scripts such as `build-apk-ondevice.sh`, `bake-runtime.sh`, and `patch-webui.sh`.

Only the compiled `classes.dex` remains. **This repository cannot currently build the APK directly.** It serves as an engineering record of how the APK was made, together with the already-built release artifact.

`HANDOFF.md` contains detailed engineering notes (628 lines), including the build pipeline and the symptoms, causes, and fixes for individual issues. It may serve as a basis for reconstruction, but it is not a substitute for the missing source code.

---

## Repository Contents

```
README.md              Chinese project overview
README.en.md           This English translation
HANDOFF.md             Detailed engineering handoff (628 lines; recommended reading)
hotupdate.md           Hot-update mechanism notes
android-port/
  bootstrap.sh         Container environment bootstrap script (31 KB, extensively commented)
  gate.html            Startup loading page
  pyproject.toml       Dependency declarations with Android patches
  uv.lock              Offline dependency lockfile
  omnivoice.json       Model manifest (13 files / 3.04 GB)
```

The APK is not stored in the repository because it exceeds GitHub's 100 MB per-file limit. It is available under **Releases**.

**Integrity information for the current public Release v0.1.0** (from GitHub Release asset metadata):

- File size: `1,201,555,019 bytes` (about 1.20 GB decimal)
- SHA-256: `8a54e52cbae13d8621e680172f42a4bbc77217b1358961996b0da35db7d78ec3`
- [Download page: Release v0.1.0](https://github.com/qftuftfutg/VoiceStudio-Android/releases/tag/v0.1.0)

After downloading, verify with `sha256sum` (Linux/macOS) or PowerShell `Get-FileHash -Algorithm SHA256`. A matching hash proves only that the file matches the asset currently uploaded to this Release. It does not prove that the build is reproducible or constitute a security audit.

---

## Installation

1. Download `VoiceStudio-Native-0.1.0.apk` (1.2 GB) from Releases.
2. Install it directly. **Termux, root, and a PC are not required.**
3. On first launch, the app prepares the base Ubuntu/Python environment. The recorded test installation took about 15–20 minutes and logged zero downloads. However, if cache files or bootstrap markers are missing, the script may access package repositories or fall back to network installation. Offline operation cannot be guaranteed for a fresh rootfs or every network environment. Downloading the OmniVoice model separately requires network access.
4. Later launches take about 50–120 seconds while PyTorch loads.

> App data and models are stored in the app-private directory or app-specific external directory. Under the normal Android uninstall process, the system generally removes app-specific data. This is not a secure-erasure guarantee and does not cover files that users export or copy elsewhere, system backups, or third-party copies. The local model will usually need to be downloaded again after uninstalling.

---

## License

This is an unofficial Android port of [VoiceStudio](https://github.com/debpalash/VoiceStudio) (AGPL-3.0) and is itself distributed under **AGPL-3.0**. The APK bundles the upstream frontend and backend, so the corresponding source must be provided as required by AGPL.

The upstream source is linked above, but this repository currently **lacks the native Android shell's Java source code and the complete APK build pipeline**. The upstream source link, `HANDOFF.md`, and adaptation files/records under `android-port/` do not automatically constitute the complete Corresponding Source for this APK. The publisher has not demonstrated that all source required to constitute the Corresponding Source for this binary version has been provided. Accordingly, this page does not claim that the source-distribution obligations of AGPL-3.0 have been fully satisfied. The corresponding source and build instructions should be restored and verified before making a compliance conclusion.

**This is not an official VoiceStudio project** and is not affiliated with the upstream author.

---

## Acknowledgements

- [VoiceStudio](https://github.com/debpalash/VoiceStudio) — upstream project, AGPL-3.0
- [proot](https://proot-me.github.io/) / [Termux](https://termux.dev/) — make it possible to run Ubuntu on Android

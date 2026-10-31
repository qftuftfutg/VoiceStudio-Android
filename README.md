# VoiceStudio for Android（非官方移植 · 半成品）

把开源语音工作站 [VoiceStudio](https://github.com/debpalash/VoiceStudio)（AGPL-3.0）
搬到 Android 上：**一个自包含的 APK，装上就能用，不需要 Termux、不需要 root、
不需要电脑**。

<p align="center">
  <a href="https://afdian.com/a/123xiaole">
    <img src="https://img.shields.io/badge/爱发电-支持作者-946CE6?style=for-the-badge" alt="爱发电赞助 / Sponsor on Afdian">
  </a>
</p>
<p align="center"><strong>自愿支持项目维护 · Voluntarily support project maintenance</strong> · <a href="SPONSOR.md">赞助说明 / Sponsorship</a></p>

> ⚠️ **先说清楚：这是一个半成品。**
> 核心链路是通的（环境自举 → Python 后端 → 界面全量可用），但还有已知问题没解决，
> 而且**原生壳的 Java 源码在本项目整理过程中丢失了**，仓库里只有 Android 侧的
> 适配文件与完整工程记录。详见下面「现状」和「缺什么」。

---

## 它是什么

```
APK（1.2 GB，全自包含）
├── WebView ──── 加载官方前端（assets/webui）
├── 原生壳 :3900 ── 静态资源 + 启动闸门 + 兜底桩 + 反向代理
├── proot（改名成 libvsproot.so 放进 lib/arm64-v8a/）
└── Ubuntu 24.04 rootfs（assets 里的 tar.gz，首次启动解包）
         └── uvicorn :3901 ← 真正的 VoiceStudio Python 后端
```

几个花了大力气才做对的地方：

- **本次测试安装记录为零下载**：测试包记录包含 338 个 `.deb` 和 295 个 Python wheel，安装日志中的 `Downloading` 计数为 **0**，耗时约 15–20 分钟。但这不是对所有安装环境的离线保证：`bootstrap.sh` 在 `/root/.vs-bootstrap/base` 标记不存在时会执行 `apt-get update`，缓存不完整时还会等待宿主机下载或回退到网络安装。是否真正离线取决于 APK/rootfs 是否包含完整缓存及预置状态。
- **启动闸门**。后端要 import PyTorch，冷启动要 1–3 分钟。这期间前端页面虽然能打开，
  但会请求到还不存在的路由而崩在错误边界上（那张错误页还没有返回入口）。
  所以引擎没起来之前不放前端页面出去，先显示一张真实的进度页。
- **接口预热**。`/health` 通过还不等于能用 —— `/engines` 首次要 31 秒、
  `/setup/preflight` 首次 13 秒（之后 1.4 秒 / 0.45 秒）。加载页会先把前端首屏
  要用的 20 个接口打一遍，热了才放行，界面一出现就是可用的。
- **处理测试固件上的 `/proc` 访问失败**。在本项目唯一验证过的 V2463A / Android 16 固件与应用上下文中，后端读取 `/proc/stat` 收到 `PermissionError`，导致 psutil 初始化失败。该观察是设备/ROM/访问上下文相关结果，不能推广为“所有 Android 16 设备都禁止普通 App 读取 `/proc/stat`”。实现通过运行时实际打开探测，仅在目标文件确实不可读时才用 proot 绑定替身文件。

---

## 现状

**能用的**

- 首次安装 → 环境自举 → Python 后端起来 → 界面全量可用，整条链路在真机跑通
- 后端日志确认：`Deferred startup complete — all routes live.`
- 模型包（OmniVoice 3.27 GB / 13 个文件）能下载进应用私有目录

**已知问题**

| 问题 | 说明 |
|---|---|
| 后端下载 worker 会挂死 | 任务停在 `downloading 0 B` 且「取消」按钮无效（取消是「尽力而为」设计，要等重试边界；worker 挂死后永远等不到）。重启应用可清掉。**根因未查** |
| 冷启动 50–120 秒 | 几乎全是 PyTorch import，绕不开。已用加载页给出真实进度 |
| `/engines` 首次 31 秒 | 已用预热掩盖，但没有真正解决 |
| 只有 CPU | 没有 GPU 加速，TTS 合成慢 |

**实测环境**

| 项目 | 值 |
|---|---|
| 机型 | vivo V2463A（骁龙 8 Elite / SM8750，8 核，14 GiB RAM）|
| 系统 | Android 16（API 36），arm64-v8a，1440×3168 / 640dpi |
| 首次安装 | 约 15–20 分钟，全程离线 |
| 之后冷启动 | 约 50–120 秒 |
| 装完后占用 | 根文件系统约 4.8 GB |

**兼容性边界**：本项目目前只在上述一台 V2463A 设备及其当前固件上验证过。Android 版本号本身不足以预测 `/proc` 访问权限；SELinux 策略、内核配置、ROM 改动、应用 UID/targetSdk 与 WebView 实现均可能影响行为。其他机型/固件均为未验证，不作兼容承诺。

---

## 缺什么（重要）

在本项目整理过程中，**原生壳的 Java 源码被误删了，没有备份**。
所以仓库里**没有**下面这些：

- `MainActivity` / `VsApi` / `LocalServer` / `BackendLauncher` / `RuntimeInstaller` /
  `ParallelFetcher` / `ModelFetcher` / `ProcShim` 等 Java 源码
- APK 构建流水线脚本（`build-apk-ondevice.sh` / `bake-runtime.sh` / `patch-webui.sh`）

它们只剩编译后的 `classes.dex`。**因此这个仓库目前无法直接构建出 APK**，
只能作为「怎么做出来的」记录 + 已构建好的成品。

`HANDOFF.md` 里有非常详细的工程记录（628 行），包括构建流水线、每一个坑的
现象/根因/修法，理论上照着能重建。

---

## 仓库内容

```
README.md              本文件
HANDOFF.md             完整工程记录（628 行，强烈建议先读这个）
hotupdate.md           热更机制说明
android-port/
  bootstrap.sh         容器内环境自举脚本（31 KB，注释密度很高）
  gate.html            启动加载页
  pyproject.toml       打过 Android 补丁的依赖声明
  uv.lock              全离线锁定文件
  omnivoice.json       模型清单（13 个文件 / 3.04 GB）
```

APK 不放在仓库里（超过 GitHub 单文件 100 MB 限制），在 **Releases** 里。

**当前公开 Release v0.1.0 完整性信息**（来自 GitHub Release asset 元数据）：

- 文件大小：`1,201,555,019 bytes`（约 1.20 GB，十进制）
- SHA-256：`8a54e52cbae13d8621e680172f42a4bbc77217b1358961996b0da35db7d78ec3`
- [Release v0.1.0 下载页](https://github.com/qftuftfutg/VoiceStudio-Android/releases/tag/v0.1.0)

下载后可用 `sha256sum`（Linux/macOS）或 PowerShell `Get-FileHash -Algorithm SHA256` 校验。哈希匹配只证明文件与当前 Release 上传资产一致，不代表构建过程可复现，也不构成安全审计结论。

---

## 安装

1. 下载 Releases 里的 `VoiceStudio-Native-0.1.0.apk`（1.2 GB）
2. 直接安装。**不需要** Termux、root 或电脑
3. 首次启动会准备基础 Ubuntu / Python 环境；本次测试包的安装记录约 15–20 分钟且下载计数为 0，但脚本在缓存/标记缺失时可能访问软件源或回退联网安装，因此不能对全新 rootfs 和所有网络环境承诺离线。后续单独下载 OmniVoice 模型包需要网络连接。
4. 之后每次启动大约 50–120 秒（在等 PyTorch 加载）

> 应用数据与模型存放在应用私有目录或应用专属外部目录。按 Android 正常卸载流程，系统通常会删除这些应用专属数据；这不是安全擦除保证，也不涵盖用户主动导出/复制到其他位置的文件、系统备份或第三方保存的副本。卸载后本地模型通常需要重新下载。

---

## 许可

本项目是 [VoiceStudio](https://github.com/debpalash/VoiceStudio)（AGPL-3.0）的
非官方 Android 移植，本身同样以 **AGPL-3.0** 分发。APK 里打包了原版前端与后端，
按 AGPL 要求需要提供对应源码 —— 上游源码在上面的链接里，
但本仓库当前**缺少原生 Android 壳的 Java 源码及完整 APK 构建流水线**。上游源码链接、`HANDOFF.md` 和 `android-port/` 中的适配文件/记录，不能自动等同于该 APK 的完整 Corresponding Source。发布者尚未证明已提供构成该二进制版本所需的全部对应源码；因此本页不作“已完整满足 AGPL-3.0 源码提供义务”的声明。应先补齐并核验对应源码与构建说明，再作合规结论。

**这不是官方项目**，与 VoiceStudio 作者无关。

---

## 致谢

- [VoiceStudio](https://github.com/debpalash/VoiceStudio) —— 上游项目，AGPL-3.0
- [proot](https://proot-me.github.io/) / [Termux](https://termux.dev/) —— 让 Android 上跑起 Ubuntu 成为可能

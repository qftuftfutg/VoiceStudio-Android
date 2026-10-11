# VoiceStudio for Android（非官方移植 · 半成品）

把开源语音工作站 [VoiceStudio](https://github.com/debpalash/VoiceStudio)（AGPL-3.0）
搬到 Android 上：**一个自包含的 APK，装上就能用，不需要 Termux、不需要 root、
不需要电脑**。

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

- **首次安装全程离线**。338 个 `.deb` + 295 个 Python wheel 全部预置在 APK 里，
  实测安装过程 `Downloading` 计数为 **0**。装完约 15–20 分钟。
- **启动闸门**。后端要 import PyTorch，冷启动要 1–3 分钟。这期间前端页面虽然能打开，
  但会请求到还不存在的路由而崩在错误边界上（那张错误页还没有返回入口）。
  所以引擎没起来之前不放前端页面出去，先显示一张真实的进度页。
- **接口预热**。`/health` 通过还不等于能用 —— `/engines` 首次要 31 秒、
  `/setup/preflight` 首次 13 秒（之后 1.4 秒 / 0.45 秒）。加载页会先把前端首屏
  要用的 20 个接口打一遍，热了才放行，界面一出现就是可用的。
- **绕开 Android 的 `/proc` 封锁**。Android 16 不给普通 App 读 `/proc/stat`，
  而 psutil 在 import 阶段就读它，直接导致后端启动失败。做法是给容器造一份
  格式合法的替身文件并用 proot 绑定覆盖（只在该文件真的读不到时才覆盖）。

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

**换别的机器要注意**：本项目**只在这一台设备上验证过**。不同 ROM 对 `/proc`
的封锁策略不一样（代码里是运行时探测，读得到就用真文件），
屏幕密度不同也会影响 WebView 的视口，这些都没有在第二台设备上测过。

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

---

## 安装

1. 下载 Releases 里的 `VoiceStudio-Native-0.1.0.apk`（1.2 GB）
2. 直接安装。**不需要** Termux、root 或电脑
3. 首次启动会自动装环境，**全程不需要联网**，约 15–20 分钟，界面上有真实进度
4. 之后每次启动大约 50–120 秒（在等 PyTorch 加载）

> 卸载即完全清除：所有数据（包括模型）都在应用专属目录里，卸载后不留残留。
> 但这也意味着**卸载 = 模型要重新下**。

---

## 许可

本项目是 [VoiceStudio](https://github.com/debpalash/VoiceStudio)（AGPL-3.0）的
非官方 Android 移植，本身同样以 **AGPL-3.0** 分发。APK 里打包了原版前端与后端，
按 AGPL 要求需要提供对应源码 —— 上游源码在上面的链接里，
本项目对上游做的改动记录在 `HANDOFF.md` 和 `android-port/` 里。

**这不是官方项目**，与 VoiceStudio 作者无关。

---

## 关于我 / 支持一下

我只是一个高中生，手里钱很紧。做这个项目把我能用的额度基本烧完了，
最后只能交上来一个半成品 —— 上面「已知问题」和「缺什么」里列的，
都是我没能做完的部分，不是我不知道。

如果你觉得这东西有用，或者只是想让这个半成品有机会被做完：

**<https://afdian.com/a/123xiaole>**

不给也完全没关系，代码和成品都在这里，随便用。

---

## 致谢

- [VoiceStudio](https://github.com/debpalash/VoiceStudio) —— 上游项目，AGPL-3.0
- [proot](https://proot-me.github.io/) / [Termux](https://termux.dev/) —— 让 Android 上跑起 Ubuntu 成为可能

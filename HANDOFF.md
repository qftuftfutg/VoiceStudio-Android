# VoiceStudio-Native 交接文档

> 把开源 VoiceStudio（AGPL-3.0，`debpalash/VoiceStudio`）搬到 Android：秒开、自带环境、卸载无残留。
> 本文件描述**当前混合架构**；旧方案见文末「历史」。

## 1. 架构

```
APK (46 MB, 全自包含)
├── WebView ──加载原版前端── assets/webui（15 MB / 303 文件，未改一行）
├── LocalServer :3900 ── 静态资源 + 内置桩(兜底) + 反代
├── proot（改名 libvsproot.so 放进 lib/arm64-v8a/）
└── Ubuntu 24.04 rootfs（assets 里的 tar.gz，首次启动解包）
        └── uvicorn :3901 ← 真正的 VoiceStudio Python 后端（全量功能）
```

- **加载闸门**：引擎没起来之前**不放前端页面出去**，先给一张原生进度页；
  就绪后自动进入应用。这不是保守，是必须的 —— 让用户提前进半死的前端
  会崩在错误边界上，而且那张错误页**没有返回入口**（见附录 I.6）
- **预热**：`/health` 通了还不算能用。实测 `/engines` 首次要 **31 秒**、
  `/setup/preflight` 首次 13 秒（之后 1.4 s / 0.45 s）。前端一进来就并发
  请求它们，界面会停在自带的「加载中…」四十多秒。所以加载页会把前端
  首屏要用的 20 个接口先打一遍，热了才放行 —— 界面一出现就是可用的
- **自动接管**：`VsApi` 三级回落 —— **真后端(3901) → 热更桩 → 内置桩**。
  ⚠️ 顺序不能反：桩排前面会把真数据永久挡在外面（曾经把 `/media-tools/status`
  钉死在 "downloading 35%"，界面上音频工具永远显示「安装中」）
- **无残留**：数据全在应用专属目录，卸载即清空（见 §4）

### 实际耗时（本机实测，骁龙 8 Elite / 8 核）

| 场景 | 耗时 |
|---|---|
| 首次安装（解包 → apt → 装 400+ wheel → 起引擎 → 预热） | 约 15–20 分钟，**全程离线** |
| 之后每次冷启动 | 约 50–90 秒（几乎全是 PyTorch import + 预热）|
| 装完后的磁盘占用 | 根文件系统约 4.8 GB（其中 venv 1.9 GB、/usr 1.4 GB）|

## 2. 端口

| 端口 | 用途 |
|---|---|
| 127.0.0.1:3900 | 原生壳，WebView 指向这里（占用则顺延 3901…3919）|
| 127.0.0.1:3901 | 真后端（uvicorn under proot）|

## 3. 热更（改完强杀重启即可，**不必重装 APK**）

路径 `/sdcard/Android/data/sh.voicestudio.app/files/`

| 位置 | 作用 |
|---|---|
| `webui/` | 覆盖前端页面（同名文件覆盖 APK 内置版本）|
| `api-stubs/<路径转下划线>.json` | 直接作为该接口响应体，例 `setup_preflight.json` → `GET /setup/preflight` |
| `bootstrap.sh` | 后端起环境脚本（改它不用重装）|
| `vsapp/` | VoiceStudio 后端源码，bind 到 rootfs 的 `/app` |
| `models/` | 模型 |

```bash
am force-stop sh.voicestudio.app && am start -n sh.voicestudio.app/.MainActivity
```

⚠️ **Java 代码与 native 库不能热更**，必须重新构建安装。

## 4. 数据位置（硬性要求：卸载必须全清，不留残留）

| 内容 | 位置 |
|---|---|
| Ubuntu rootfs、运行标记 | `/data/user/0/sh.voicestudio.app/files/{rootfs,runtime}` |
| 模型/源码/输出/热更文件 | `/sdcard/Android/data/sh.voicestudio.app/files/` |

**任何自带或生成的数据都不得写到这两处之外。**（开发期中转文件放 `/sdcard` 根算残留，要随手清）

## 5. 构建与安装

```bash
cd voicestudio-native && bash scripts/build-apk-ondevice.sh   # → dist/*.apk

# ⚠️ 不能从 /sdcard 直装（system_server 拒绝），必须先拷到 /data/local/tmp
cp dist/*.apk /sdcard/stage.apk          # bash 身份
cp /sdcard/stage.apk /data/local/tmp/a.apk && pm install -r /data/local/tmp/a.apk   # shell 身份
```

包名 `sh.voicestudio.app`。

## 6. 签名密钥（丢了要卸载重装、数据全没）

```
备份：/sdcard/Download/VoiceStudio-Native-backup/debug.keystore
原件：voicestudio-native/keys/debug.keystore
alias androiddebugkey / storepass & keypass = android
```

## 7. 进度

**已完成并实测（2026-10-11 09:40）**
- 手工 APK 流水线（无 Gradle）：aapt2 → javac → d8 → jar → apksigner
- 原版前端在 WebView 完整渲染，中文 i18n 正常，**布局按设备宽度正确排版**
- 本地服务 3900 + 三级回落 API 层 + 加载闸门 + 接口预热
- 热更通道（webui / api-stubs / bootstrap.sh）
- proot 在 Android 10+ 可执行（附录 A.1 的 W^X 绕过）
- Ubuntu rootfs 内置并可解包（手写 tar 解包器）
- **首次安装全程离线**：338 个 .deb + 295 个 wheel 全预置，实测 `Downloading` 计数为 **0**
- **Python 后端真的起来了**：`Deferred startup complete — all routes live.`
- 模型包（OmniVoice 3.27 GB / 13 文件）已下载进 HF 缓存
- 全量功能验证：`/models` `/engines` `/setup/*` `/profiles` `/media-tools/status` 全部 200

**待办 / 已知问题**
- [ ] 后端下载 worker 会挂死：任务停在 `downloading 0 B` 且「取消」按钮无效
      （取消是「尽力而为」设计，要等重试边界才生效；worker 挂死后永远等不到）。
      临时解法：重启应用（任务是纯内存状态）。根因未查，见附录 I.10
- [ ] `/engines` 首次 31 秒——已用预热掩盖，但没有真正解决
- [ ] 无 GPU：只有 CPU，TTS 合成慢

## 8. 风险

| 风险 | 说明 |
|---|---|
| 发热/内存 | proot + PyTorch 确实重。缓解：后端按需启动、用完可停 |
| 冷启动 50–90 秒 | 主要是 PyTorch import，绕不开。已用加载页给出真实进度 |
| 无 GPU | 只有 CPU，TTS 合成慢 |
| proot 性能 | 每 syscall 多一层 ptrace，且 PROOT_NO_SECCOMP=1 关掉加速 |
| 后端重启后 | `_wheels`/`_aptcache` 被清理，靠 `.vs-deps-ok` 标记跳过重装（附录 I.3 就是这里踩的）|
| AGPL-3.0 | 打包原版前端 ⇒ 整个 APK 需按 AGPL 分发并提供源码 |

---

# 附录 A：踩过的坑（实测结论，别再试第二遍）

**A.1 proot 在 Android 10+ 无法从数据目录执行**
`error=13, Permission denied`。W^X 禁止执行应用可写目录的文件。唯一可行位置是
APK 的 `lib/<abi>/`（安装时解压到 nativeLibraryDir，那里可执行）。
做法：构建时把 `proot`/`loader`/`loader32` 改名成 `libvs*.so` 放进 `lib/`。

**A.2 proot 的 DT_NEEDED（名字一个都不能改）**
```bash
strings proot | grep -oE '^lib[a-zA-Z0-9_.+-]*\.so(\.[0-9]+)*$' | sort -u
# libandroid-shmem.so / libc.so / libtalloc.so.2 / libtermux-exec.so
```
后三个都要放进 `lib/`，**保持原文件名**（链接器按 SONAME 找）。

**A.3 proot 下 apt 会卡死（不是慢）**
```bash
apt-get -o APT::Sandbox::User=root -o Acquire::ForceIPv4=true update
```
apt 默认切 `_apt` 用户下载，proot 里 setuid 失败 → 永远挂着；IPv6 会先试再超时。

**A.4 rootfs 的 resolv.conf 是空的** → DNS 不通，什么都下不动。
显式写 `nameserver 223.5.5.5`。

**A.5 Ubuntu 24.04 arm64 的源是 `ports.ubuntu.com`**
换镜像必须覆盖 `archive.` / `security.` / **`ports.`** 三个域名。
**且别用标记文件跳过这步** —— 第一版就因此被永久跳过，apt 一个包都装不上。

**A.6 ONNX Runtime 两个坑**
- `classes.jar` **必须作为 d8 的输入**（不只是 javac classpath），否则
  `ClassNotFoundException: ai.onnxruntime.OrtEnvironment`
- 每个 ABI 有**两个** .so：`libonnxruntime.so` + `libonnxruntime4j_jni.so`，
  少打后者 → `UnsatisfiedLinkError: "libonnxruntime4j_jni.so" not found`

**A.7 包名不能含 Java 关键字**：`native` 会让 R.java 报 `<identifier> expected`。

**A.8 原版前端的接口必须逐个对齐，猜必翻车**
拿到 `undefined` 就 `.filter()`，被错误边界捕获成整页报错。踩过的：
`/models/install/status` 真实返回**只有** `{"jobs":[...]}`；
`/media-tools/status` 的 `acquire` 在 **`ops`** 下，不在顶层。
**修法：去 `backend/api/routers/` 读真实返回。**

**A.9 设备操作**
- `pm install` 不能从 `/sdcard` 装，先拷 `/data/local/tmp`
- `shell`(uid 2000) 有 ~60 秒超时，超时被 SIGTERM 且丢输出
- **别用 `pkill -f`** —— 模式匹配自身 argv，会自杀（踩过两次）
- `shell` 读不到应用私有目录；跨身份传文件必须经 `/sdcard` 中转

---

# 附录 B：手工构建流水线（无 Gradle）

组件用 `apt-get download` + `dpkg-deb -x` 解包到隔离目录 `.vsbuild/`，
**绝不** `apt-get install`。

```
aapt2 compile → aapt2 link → javac --release 17 → d8 → jar uf → apksigner
```

- `LD_LIBRARY_PATH` 必须指向解包的 `usr/lib`（Termux 程序把路径写死在 RUNPATH）
- Termux 包依赖要**读 deb 的 Depends 递归解析**，别手写清单
- 清单的 `package` 属性由脚本注入（aapt2 link 强制要求）
- `android.jar` 从 Google `repository2-3.xml` 解析真实文件名
- 完整脚本：`voicestudio-native/scripts/build-apk-ondevice.sh`

---

# 附录 C：历史（都已被取代）

1. **纯 proot 版**（`voicestudio-android`）—— 已整份删除。首次 40–60 分钟、2 GB、
   启动数秒。踩过 `/proc/stat` 权限坑（Android 10+ `untrusted_app` 读不到，
   `psutil.cpu_percent()` 崩溃），用 `ProcShim` + proot `-b` 绑定解决。
   **附带结论：proot 按最长路径匹配，`-b` 顺序无关。**

2. **纯原生 ONNX 版** —— 只做到 RVC 变声 + 降噪子集。三个模型接口已实测：
   FCPE `audio[1,N,1]→f0_hz[1,F,1]`；ContentVec `source[1,1,N]→embed[...,768]`；
   RVC `phone/phone_lengths/pitch/pitchf/ds/rnd→audio`。
   **结论：原生重写永远到不了全量** —— VoiceStudio 的「音频克隆」是
   **ASR 转写 + TTS 用克隆音色重念**（`voice_convert.py:228→324`），不是 RVC，
   而那一堆 TTS 引擎无法在无 PyTorch 的环境里重写。

3. **全量功能 = 必须跑真 Python 后端** —— 当前混合架构由此而来。

---

# 附录 D：预烘焙（把装好的环境打包带走）

**动机**：首次安装要在 proot 里跑 apt + uv sync，40–60 分钟。这软件几乎不会二次更新，
所以「一台机器装好的结果」应该打包内置，新用户解压即可。

**已就绪的三段式实现**

| 环节 | 位置 |
|---|---|
| 打包 | `scripts/bake-runtime.sh` —— 产出 `assets/baked/{venv,aptcache}.tar.gz`，内部顶层目录名已对齐解包目标（`.venv/` / `_aptcache/`）|
| 解包 | `RuntimeInstaller.ensureBaked()` —— 首次启动释放到 `<externalFiles>/vsapp/`，带 `.baked-<name>-<ver>` 标记，幂等 |
| 使用 | `bootstrap.sh` —— 有 `_aptcache/*.deb` 就先本地装（跳过下载）；有 `.venv` 就跳过 `uv sync` |

**体积实测与上限**

| 内容 | 大小 |
|---|---|
| 现有 APK（前端 15M + rootfs 30M + 后端源码 28M + proot/ORT） | 67 MB |
| `k2-fsa/OmniVoice`（必需 TTS 模型，13 个文件） | **3.04 GB** |

⚠️ **APK 是 ZIP，总大小受 4 GB 限制**（超出需 ZIP64，aapt2 不一定支持）。
把模型也塞进去会到 ~4.5 GB，**大概率构建失败**。
建议：**环境烘进 APK，模型首次运行时由后端从 hf-mirror 下载**（3 GB ≈ 7 分钟）。

**收割步骤**（环境建好后执行）

```bash
# 1) shell 身份（uid 2000）把东西拷到共享目录——bash 读不到别的应用的外部目录
cp -r /sdcard/Android/data/sh.voicestudio.app/files/vsapp/.venv     /sdcard/vsn-bake/venv
cp -r /sdcard/Android/data/sh.voicestudio.app/files/vsapp/_aptcache /sdcard/vsn-bake/aptcache
# 2) bash 身份打包
bash scripts/bake-runtime.sh /sdcard/vsn-bake
# 3) 重新构建 APK
```

# 附录 E：文件系统限制（实测）

- **`/sdcard` 不支持符号链接**（FUSE 文件系统，`ln -s` 失败）。
  影响：HuggingFace 缓存靠 `snapshots/` 符号链接指向 `blobs/`，
  **不能**把 HF 缓存放 `getExternalFilesDir()`。
  正确做法：放**私有** `getFilesDir()`（ext4，支持符号链接，且同样随卸载清除）。
- 应用私有目录 `filesDir` 可放心用（ext4/f2fs，符号链接、可执行位正常）。
- 但**可执行**文件仍不能放私有目录（W^X），见附录 A.1 —— 只有 `lib/<abi>/` 能执行。
- 跨身份传文件必须经 `/sdcard` 中转：`shell`(uid 2000) 读不到应用私有目录，
  `bash`(应用身份) 读不到**别的**应用的外部目录。

# 附录 F：安装与调试的两个硬要点

**F.1 安装必须加 `-g`**

```bash
pm install -r -g /data/local/tmp/a.apk     # ✅ Success
pm install -r    /data/local/tmp/a.apk     # ❌ INSTALL_FAILED_ABORTED: User rejected permissions
```

因为 manifest 里声明了 `POST_NOTIFICATIONS` / `FOREGROUND_SERVICE*`，
厂商系统会弹权限确认；非交互式安装下直接被拒。`-g` 表示自动授予全部运行时权限。

**F.2 bootstrap 的日志在外部目录，不要依赖 logcat**

脚本开头就把所有输出 tee 到 `/app/_bootstrap.log`
（即 `<externalFiles>/vsapp/_bootstrap.log`，手机上是
`/sdcard/Android/data/sh.voicestudio.app/files/vsapp/_bootstrap.log`）。

原因：apt/uv 跑起来后系统日志量很大，会**把我们的 tag 冲出环形缓冲**，
`logcat -s VoiceStudio` 经常什么都读不到 —— 排查时会误判成「进程莫名消失」。

同时脚本里加了 `trap ... ERR`，任何未捕获错误都会记下行号。

**F.3 进程死亡用 `dumpsys activity exit-info` 查，不要猜**

```bash
dumpsys activity exit-info sh.voicestudio.app
```

实测抓到过的真实死因：

| reason | 含义 | 触发场景 |
|---|---|---|
| `6 (ANR)` subreason=`bg anr: Input dispatching timed out` | 后台输入超时被杀 | apt 满载 CPU → UI 抢不到 → 后台 ANR → SIGKILL；**proot 是子进程，跟着一起死** |
| `10 (USER REQUESTED)` subreason=`21 (FORCE STOP)` | 被 `am force-stop` | 安装新 APK 时必然发生，**会连带杀掉正在跑的 bootstrap** |

结论：**后端必须由前台服务承载**（`isForeground=true` + 常驻通知），
否则每次 CPU 满载都会被系统当后台 ANR 清掉。

# 附录 G：暂停 / 恢复首次安装

**为什么需要专门机制**：后端跑在**前台服务**里且 `START_STICKY`，
所以 `am force-stop` 会在几秒内被系统重新拉起——拦不住。
（服务是 `exported="false"`，`am startservice` 也发不进去：shell 无权限。）

**机制**：bootstrap 脚本开头检查 `/app/_paused`（即
`/sdcard/Android/data/sh.voicestudio.app/files/vsapp/_paused`），存在就直接退出。

```bash
# 暂停（让出带宽）
touch /sdcard/Android/data/sh.voicestudio.app/files/vsapp/_paused
am force-stop sh.voicestudio.app          # 重启后脚本立即退出

# 恢复
rm /sdcard/Android/data/sh.voicestudio.app/files/vsapp/_paused
am start -n sh.voicestudio.app/.MainActivity
```

**进度不会丢**：已下载的 `.deb` 在 rootfs 的 `/var/cache/apt/archives`，
apt 索引在 `/var/lib/apt/lists`，`uv` 缓存在 `UV_CACHE_DIR`——
都在应用私有目录里，恢复后从断点继续。

**为什么当初要暂停**：实测宿主侧镜像速度掉到 **87 KB/s**（早前 670 KB/s），
45 秒内 apt 只写入 7 KB —— 不是死锁，是在等一个几乎不动的连接。
按那个速度 apt 还要 30 分钟、`uv sync` 要 3 小时以上。

**判断「卡住 vs 正常慢」的方法**：
```bash
A=$(df -k /data/user/0 | tail -1 | awk '{print $4}'); sleep 45
B=$(df -k /data/user/0 | tail -1 | awk '{print $4}'); echo $(( (A-B)/1024 )) KB
ps -A -o PID,STAT,ARGS | grep apt-get     # 状态 t = ptrace 停止（proot 下正常态）
```
`t` 不代表死锁（proot 的 tracee 平时就是 ptrace 停止的），要看**磁盘写入量**和**宿主侧镜像速度**。

# 附录 H：把首次安装从「几小时」压到「几分钟」

**问题**：apt 在 proot 里只单连接下载，而镜像**对单连接限速**。
实测同一文件：单连接 **82 KB/s**、6 连接 **571 KB/s**、32 连接 **2.9 MB/s**。
202 MB 的依赖按单连接要 40 分钟，实际几小时都装不完。

## 三个必须一起做的优化

### H.1 并行下载（32 连接）

```bash
bash scripts/parallel-fetch.sh <uris.txt> <outdir> 32
```

清单从哪来 —— **让 apt 只解析不下载**：

```bash
apt-get $APT_OPTS install -y --no-install-recommends --print-uris $PKGS \
  | grep -oE "https?://[^']+\.deb" | sort -u > "$APP_DIR/_apt-uris.txt"
```

### H.2 单个大文件要**分段并发**

`libllvm20`（27 MB）单连接要 20 分钟；切成 32 段并发 → **8 秒**。

```bash
SZ=$(curl -sSI "$U" | grep -i content-length | awk '{print $2}')
PART=$(( (SZ + 31) / 32 ))
for i in $(seq 0 31); do
  s=$((i*PART)); e=$((s+PART-1)); [ $e -ge $SZ ] && e=$((SZ-1))
  curl -sSf -r ${s}-${e} -o "$F.p$i" "$U" &
done; wait; cat "$F".p* > "$F"; rm -f "$F".p*
```

### H.3 ⚠️ 最容易踩错的一步：`.deb` 放哪里

```bash
# ❌ 错：apt 仍然联网下载（日志会显示 Need to get 199 MB）
apt-get install -y /app/_aptcache/*.deb

# ✅ 对：放进 apt 自己的缓存目录，apt 自动复用、跳过下载
cp /app/_aptcache/*.deb /var/cache/apt/archives/
apt-get install -y $PKGS
```

实测差别：**Need to get 199 MB → 49.9 MB**（省 149 MB）。

### H.4 文件名必须 URL 解码

从 `--print-uris` 拿到的 URL 里 `~` 写作 `%7e`、`+` 写作 `%2b`。
若按 URL 原样命名保存，**apt 认不出缓存文件**（它按真实包名找）。

```bash
name="$(basename "$url" | sed 's/%7[Ee]/~/g; s/%2[Bb]/+/g')"
```

## 完整握手流程

```
bootstrap: apt update → --print-uris 生成 _apt-uris.txt → 等 _aptcache/.ready（最多 40 分钟）
宿主机  : 读清单 → 32 连接并行下载（大文件分段）→ 放进 _aptcache → 写 .ready
bootstrap: 把 _aptcache/*.deb 拷进 /var/cache/apt/archives/ → apt-get install（几乎不下载）
```

预烘焙进 APK 后，新用户直接有 `_aptcache`，**整个握手都跳过**。

## 其余减速项

- **`shell`(uid 2000) 读不到应用私有目录**；`bash`(应用身份) 读不到**别的**应用的外部目录。
  跨身份传文件必须经 `/sdcard`。这条今天误判了两次。
- `ps -o ARGS | grep xxx` 在本机**偶发漏报**（apt 明明在跑却查不到）。
  判断存活用 `ps -A -o PID | grep -qx <pid>`。

# 附录 I：最后一轮修复与现状（2026-10-11 09:50）

> ⚠️ **现状先说清楚**：按用户要求，除了**交付的 APK、签名密钥、本文档**，
> 其余的（插件、设备上的应用与其全部数据、构建工具链、工程源码）
> **都已经删掉了**。所以下面这些内容不是「待办」，而是**踩坑记录** ——
> 万一以后要重做，照着这份记录能少走几天弯路。

## I.0 交付物在哪

| 东西 | 路径 |
|---|---|
| APK（1.2 GB，`sh.voicestudio.app` v0.1.0） | `/sdcard/Download/VoiceStudio-Native-0.1.0.apk` |
| 签名密钥（丢了要卸载重装、数据全没） | `/sdcard/Download/VoiceStudio-Native-backup/debug.keystore` |
| 本文档 | `/sdcard/Download/HANDOFF.md` |

签名：`alias androiddebugkey / storepass & keypass = android`

## I.1 全离线安装被两个「URL 直链」依赖破坏

**现象**：APK 里预置了 295 个 wheel，装的时候照样联网下载一百多 MB。

**根因**：`pyproject.toml` 里两个依赖写成 URL 直链：
```
kittentts @ https://gh-proxy.com/.../kittentts-0.8.1-py3-none-any.whl
en-core-web-sm @ https://gh-proxy.com/.../en_core_web_sm-3.8.0-py3-none-any.whl
```
uv **不接受**用 `--find-links` 里的同名 wheel 顶替 URL 直链依赖：
```
error: Failed to download `kittentts @ https://...`
  cause: Network connectivity is disabled, but the requested data wasn't found in the cache
```
离线一失败就退回联网，**预置的 wheel 等于白带**。

**修法**：改成普通的「名字==版本」，`--find-links` 就成了它的来源：
```toml
"kittentts==0.8.1",
"en-core-web-sm==3.8.0",
```
代价：桌面端 `uv pip install --system .` 解析不到 spaCy 模型（PyPI 上没有），
要用那条路径得自己补 `--find-links`。Android 端不受影响。

## I.2 `sphn` 必须用预编译 wheel，否则要联网编译 11 分钟

`sphn` 在 PyPI 上**只有 mac arm64 / x86_64 / win 的轮子，没有 linux-aarch64**，
只能源码编译；它的 build 依赖 maturin，maturin 又去 `static.rust-lang.org`
拉 rustup —— 这里慢且不稳，实测链式失败：lock file v4 需要 cargo ≥1.78 →
装 rustup → `audiopus_sys` 找不到 Opus → 补 libopus-dev …**编一次 11 分 32 秒**。

**修法**：把编好的 `sphn-0.2.1-cp312-cp312-linux_aarch64.whl`（14.7 MB）放进 `_wheels`。
bootstrap 里本就有 `if ! ls _wheels/sphn-*.whl` 的判断，有 wheel 就整段跳过。

⚠️ 但**只有离线路径才会用到它**：联网路径里 uv 优先用索引，会挑中 sdist 现场编译。
所以 I.1 和 I.2 是一件事的两面 —— **离线路径走通，两个问题一起消失**。

## I.3 重启就坏：三处「看载荷在不在」的误判

**现象**：首次安装一切正常；**强杀重启后 App 卡在启动中，日志不再增长**。

收尾清理会删掉 `_wheels` / `_aptcache`（1.1 GB 过程产物），但有三处判断是
「看载荷在不在」，删掉之后全部误判：

| 位置 | 误判成 | 后果 |
|---|---|---|
| 编译工具段 | 「需要编译器」 | 每次开机重装 Rust 工具链（5–8 分钟，还要联网）|
| 权限统一段 | 通配符不匹配 | `chmod .../_aptcache/*` 返回 1 → `[TRAP] 第 416/417/418 行失败` |
| 体积自检 | 无条件执行 | 每次开机对 4.8 GB rootfs 做 `du -sh /`，**卡十几分钟** |

第三条最致命：自检写在「启动后端」**前面**，proot 下每个 syscall 都过 ptrace，
`du -sh /root/.venv` 一个目录就要一分多钟 —— 后端永远等不到。

**修法**：
- 编译工具段加上 `[ ! -f "$VENV_DIR/.vs-deps-ok" ]` —— 依赖装好了就不需要编译器
- 权限段逐目录判断，别让通配符空展开
- 自检改成**只跑一次**（标记文件）**且丢到后台**（`( ... ) &`）——
  诊断信息永远不该挡在启动路径前面

## I.4 后端从来没起来过：Android 封了 `/proc/stat`

**现象**：uvicorn 先绑上 3901、`/health` 短暂回 503 "starting"，紧接着进程退出：
```
PermissionError: [Errno 13] Permission denied: '/proc/stat'
FATAL: backend startup failed during 'api_routes'
```

**根因**：Android 16 对普通 App 封了这几个文件（连 App 自己都读不到）：
`/proc/stat`、`/proc/uptime`、`/proc/loadavg`、`/proc/version`、`/proc/diskstats`、`/proc/net/dev`
（`/proc/meminfo`、`/proc/cpuinfo`、`/proc/self/*` 仍可读）。
而后端在 **import 阶段**就读它：
```
backend/api/routers/system.py:48   psutil.cpu_percent(interval=None)
  → psutil/_pslinux.py cpu_times() → open("/proc/stat") → PermissionError
```

**修法**：`ProcShim.java` —— 造格式合法的替身文件，用 proot `-b 替身:/proc/stat` 覆盖。
```
stat / uptime / loadavg / version / diskstats  → 合成
（没有 net/dev：/proc/net 是指向 /proc/self/net 的魔法软链，proot 绑不进去；
  而后端没有任何地方用 net_io_counters，先放着）
```
三个关键细节：
- **只在真读不到时才覆盖**。能读的设备必须用真文件，否则界面上的 CPU 曲线会被
  静态替身钉死成 0。探测要用「真打开读一个字节」，**不能只信 `File.canRead()`**
  （有些 ROM 的 SELinux 让 access(2) 通过、open(2) 失败）
- 绑定必须排在 `-b /proc` **后面**：proot 按路径长度匹配，更具体的才能盖住 `/proc`
- `btime` 必须是「现在 − 已开机秒数」，`psutil.boot_time()` 就靠这行

## I.5 前端崩溃 `reading 'toLowerCase'`：`/models` 的桩少了 `role`

**现象**：点着向导就崩在错误边界上，而且**那张错误页没有返回入口**，用户只能干瞪眼。

**根因**：前端有个函数无保护地调 `model.role.toLowerCase()`：
```js
function vm(e){ if(e.dictation_id) return 'dictation';
  let t = e.families?.find(...); if(t) return t;
  let n = e.role.toLowerCase();   // ← families 有可选链，role 没有
  ... }
```
真后端 `/models` 每条记录都带 `role`（实测 15,946 字节、二十多个模型）；
而内置桩只回两条、**没有 `role`**（约 400 字节）→ 必崩。

**修法**：桩里补上 `role` / `engines` / `required` / `supported` / `curated` / `incomplete`。
**凡是前端会无条件访问的字段一个都不能少。**

同类前科：`/models/install/status` 少了 `jobs` 键 → `data.jobs.filter` 崩；
`/media-tools/status` 少了 `ops.acquire` → 同样崩。**桩的形状必须照抄真响应。**

## I.6 加载闸门 + 预热（本轮最大的体验改动）

就算修好 I.5，还有一类问题绕不开：后端启动那 1–3 分钟里，前端每个页面都可能
在请求还没注册的路由，拿到 404 或形状不对的数据。

**修法**：`VsApi.handle()` 在放行静态文件之前拦一道：
```java
if ("/__ready".equals(path)) return LocalServer.Response.json(readyJson());
if (("/".equals(path) || "/index.html".equals(path)) && !backendReady()) {
    return gatePage();     // assets/gate.html
}
```
加载页轮询 `/__ready`，就绪后 `location.replace('/')` 自动进入。

⚠️ **`backendReady()` 不能用 `proxy.isUp()` 代替**。`isUp()` 只看 3901 有没有人监听，
而 uvicorn 是**先绑端口、后注册路由**：延迟启动阶段端口通了但路由还不存在，
请求只会拿到 404。必须真去要一次 `/health`，只有回 `"status":"ok"` 才算活着。

⚠️ 而**活着也不等于能用**：`/engines` 首次 31 秒、`/setup/preflight` 首次 13 秒。
所以健康之后还要预热（3 条线并行跑 20 个接口），热了才放行。
状态机：`ST_HEALTH → ST_WARM（显示「正在预热引擎…」）→ ST_READY`。

## I.7 布局被裁：WebView 没开 `useWideViewPort`

**现象**：界面只显示整页左边三分之一，右边被裁掉，正文被挤成一行七八个字。

**根因**：`WebSettings.useWideViewPort` **默认是 false**，此时 WebView **忽略**
页面的 `<meta name="viewport" content="width=device-width, initial-scale=1.0">`，
改用 980 CSS px 的默认桌面布局宽度。本机 1440px / 640dpi → 真实 CSS 视口只有 360px。

**修法**：
```java
ws.setUseWideViewPort(true);
ws.setLoadWithOverviewMode(false);   // 要的是「按设备宽度重排版」，不是「把桌面版缩小」
```

## I.8 底部横幅永不消失：主线程网络 I/O

**现象**：引擎早就就绪，底部横幅还一直压在界面上挡内容。

**根因**：`MainActivity.watchBackend` 在主线程调 `api.getProxy().isUp()`，
而它内部是 `new Socket().connect(...)` → 主线程网络 I/O 抛
`NetworkOnMainThreadException`，又被外层 `catch (Throwable ignored)` 静静吃掉
→ 判定永远「没就绪」→ 横幅永远不消失。

**修法**：改读 `VsApi.isReady()`（纯内存状态位，由加载页轮询推进，主线程安全）。

## I.9 「跳转会员」页面：改路由而不是删页面

`/pro` 是 Pro 会员营销页（US$99/年）。入口是设置侧栏「支持项目」→
`/settings/support?compare=true` → `beforeLoad` 里 `throw redirect({to:'/pro'})`。
更麻烦的是**路由状态会被持久化**，进过一次之后每次冷启动都直接落在那里。

**修法**：不删页面、不删路由，把路由本身变成「进来就弹回首页」：
```js
// android/app/src/main/assets/webui/assets/index-_Ct1mhI1.js
// 改前： path:`/pro`, component:Dx
// 改后： path:`/pro`, beforeLoad:()=>{ throw _l({to:`/`}) }
```
`_l` 是文件里**自己已经在用**的重定向原语，不引入新符号。
入口可能不止一处，堵入口容易漏，改路由才稳。

改动写成了 `scripts/patch-webui.sh`（幂等、唯一性校验、`node --check` 语法检查、
失败自动还原），原文件备份在 `backup/index-_Ct1mhI1.js.orig`。

## I.10 已知未解：后端下载 worker 会挂死

**现象**：模型页出现一个 `downloading 0 B / 5.25 GB`、速率 0 的任务，
点「取消」没反应，重启后才消失。

**根因**（定位到机制，未定位到触发条件）：
- `/models/install/status` 报 `downloading` 的依据只是内存里的 `_active_installs`
  集合，worker 线程死了条目还留着
- 「取消」是**尽力而为**设计（源码注释自己写了）：只是把 repo 加进 `_cancelled`，
  要等 worker 在**下一次重试边界**去读；worker 挂死后永远走不到那里
- 所以按钮点了等于没点

**临时解法**：重启应用（纯内存状态，重启即清）。
**未查**：worker 为什么会挂死，怀疑与分段下载 / 镜像侧有关。

## I.11 如果以后要重做：验证清单

全部走 `127.0.0.1:3900`（这一层就是 WebView 看到的东西）：

| 检查 | 期望 |
|---|---|
| `curl 3900/__ready` | 启动期 `{"ready":false,...}`，就绪后 `{"ready":true}` |
| `curl 3900/` | 未就绪→含「正在启动本地引擎」；就绪→真前端 |
| `curl 3900/models` | **约 15 KB**（真后端）。只有几百字节说明回落到了内置桩 |
| `curl 3900/health` | `{"status":"ok","device":"cpu","version":"0.5.6"}` |
| `curl 3901/health` | 同上（直连真后端）|

⚠️ **App 切到后台会被系统冻结，3900 就不响应了**，`curl` 得到 `000`。
这不是故障，切回前台立刻恢复。排查时先确认这一点，别误判。

安装命令：
```bash
# ⚠️ 不能从 /sdcard 直装（system_server 拒绝），必须先拷到 /data/local/tmp
cp /sdcard/Download/VoiceStudio-Native-0.1.0.apk /data/local/tmp/a.apk   # shell 身份
pm install -r -g /data/local/tmp/a.apk
```

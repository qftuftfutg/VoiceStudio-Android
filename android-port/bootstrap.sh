#!/bin/bash

# ── 暂停开关 ─────────────────────────────────────────────
# 存在 /app/_paused 就直接退出。网络很差时用来让出带宽：
# 前台服务是 START_STICKY，am force-stop 会被立刻拉起，所以用标记文件控制。
# 恢复：删掉该文件并重启应用。
if [ -f /app/_paused ]; then
  echo "[STEP] 已暂停（/app/_paused 存在）——删掉它并重启应用即可继续"
  exit 0
fi
# ============================================================================
#  bootstrap.sh —— 在 proot 的 Ubuntu rootfs 里准备 VoiceStudio 后端环境
#
#  热更位置：<externalFiles>/bootstrap.sh   （存在则优先于 APK 内置版本，
#            改这个文件不用重装 APK，强杀应用重启即可生效）
#
#  要点：
#   • 幂等：每步先查是否已完成，中断后重跑不会从头来
#   • 进度用 [STEP] 前缀输出，原生壳解析后显示到界面
#   • 后端监听 3901：原生壳占 3900 并反代过去
# ============================================================================
set -u
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin
export HOME=/root

APP_DIR=/app
BE_PORT=3901
# venv 放 rootfs（app 私有 ext4）：/app 在 FUSE 上不支持符号链接，建不了 venv。
VENV_DIR=/root/.venv
MARK=/root/.vs-bootstrap

# ── CPU 自适应 ───────────────────────────────────────────────────────────
# 手机全核跑推理会明显发热、掉电快。这里按**设备实际核心数**算一个上限，
# 而不是写死：8 核 → 4，6 核 → 3，4 核 → 2，最少 2、最多 6。
# 想手动调，在 /app/_threads 里写一个数字即可（覆盖自适应的结果）。
CORES=$(nproc 2>/dev/null || echo 4)
[ "$CORES" -gt 16 ] 2>/dev/null && CORES=16
VS_THREADS=$(( CORES / 2 ))
[ "$VS_THREADS" -lt 2 ] && VS_THREADS=2
[ "$VS_THREADS" -gt 6 ] && VS_THREADS=6
if [ -f "$APP_DIR/_threads" ]; then
  want=$(tr -dc '0-9' < "$APP_DIR/_threads" 2>/dev/null | head -c 2)
  [ -n "$want" ] && [ "$want" -ge 1 ] 2>/dev/null && [ "$want" -le 16 ] 2>/dev/null && VS_THREADS=$want
fi
# 这些变量是 PyTorch / OpenBLAS / MKL / numexpr 共同的线程开关，
# 设了它们，推理时就不会把 8 个核全占满。
export OMP_NUM_THREADS="$VS_THREADS"
export MKL_NUM_THREADS="$VS_THREADS"
export OPENBLAS_NUM_THREADS="$VS_THREADS"
export NUMEXPR_NUM_THREADS="$VS_THREADS"
export VECLIB_MAXIMUM_THREADS="$VS_THREADS"
export TOKENIZERS_PARALLELISM=false
# 降低内存碎片（Python 多线程常见几 GB 的虚高占用）
export MALLOC_ARENA_MAX=2
# 编译/下载阶段也别全核跑，否则装完手机烫手
export CARGO_BUILD_JOBS="$VS_THREADS"
export MAKEFLAGS="-j$VS_THREADS"
echo "[INFO] CPU 自适应: 设备 $CORES 核 → 推理/编译线程 $VS_THREADS（可写 /app/_threads 覆盖）"

# 把全部输出同时写一份到 /app/_bootstrap.log —— /app 是 bind 进来的应用外部目录，
# 开发时可以直接读，不用依赖 logcat（系统日志量大时会把我们的 tag 冲掉）。
mkdir -p "$APP_DIR" 2>/dev/null
exec > >(tee -a "$APP_DIR/_bootstrap.log") 2>&1

step() { echo "[STEP] $*"; }
ok()   { echo "[OK] $*"; }
fail() { echo "[FAIL] $*"; exit 1; }

# 任何未捕获的错误也记下来（含行号），否则挂了完全看不出是哪一步
trap 'echo "[TRAP] 第 $LINENO 行失败，退出码 $?"' ERR

echo "=============== bootstrap 开始 $(date) ==============="

mkdir -p /root "$MARK" /var/lib/apt/lists/partial /etc/apt/apt.conf.d

# ── 0. DNS：proot 里 rootfs 自带 resolv.conf 往往是空的 ──────────────────
if [ ! -s /etc/resolv.conf ] || ! grep -q nameserver /etc/resolv.conf 2>/dev/null; then
  step "准备网络环境"
  printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n' > /etc/resolv.conf
fi
ok "DNS: $(grep -m1 nameserver /etc/resolv.conf 2>/dev/null)"

# ── 1. apt 换国内镜像 ────────────────────────────────────────────────────
# 注意：这一步**不能**用标记文件跳过 —— 第一版在 ports.ubuntu.com 上没匹配到，
# 留下标记后就被永久跳过了，导致后来 apt 一个包都找不到。
step "准备软件源"
for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
  [ -f "$f" ] || continue
  sed -i -E 's@https?://[a-z0-9.]*archive\.ubuntu\.com@http://mirrors.aliyun.com@g' "$f"
  sed -i -E 's@https?://[a-z0-9.]*security\.ubuntu\.com@http://mirrors.aliyun.com@g' "$f"
  sed -i -E 's@https?://[a-z0-9.]*ports\.ubuntu\.com@http://mirrors.aliyun.com@g' "$f"
done
echo "--- 当前 apt 源 ---"
grep -rhE '^(deb |URIs:)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | head -5

# ── 2. 基础包 ────────────────────────────────────────────────────────────
# ⚠️ proot 下 apt 必须关掉两个东西，否则会**卡住不动**（不是慢，是永远不返回）：
#   APT::Sandbox::User=root —— apt 默认切到 _apt 用户跑下载，proot 里 setuid 会失败，
#                              表现为 update 一直挂着、日志无输出
#   Acquire::ForceIPv4=true —— 没有 IPv6 时 apt 会先试 v6 再超时，每个源多等几十秒
APT_OPTS="-o APT::Sandbox::User=root -o Acquire::ForceIPv4=true -o Acquire::Retries=3"
PKGS="python3 python3-venv python3-pip curl ca-certificates git build-essential pkg-config libsndfile1 ffmpeg"

if [ ! -f "$MARK/base" ]; then
  step "获取软件包清单"
  nice -n 10 apt-get $APT_OPTS update 2>&1 | tee -a "$APP_DIR/_bootstrap.log" | tail -3 || fail "apt update 失败"

  # ── 并行下载握手 ──────────────────────────────────────────────────────
  # 实测：镜像对**单连接**限速 ~82 KB/s，而 6 条并发能到 ~571 KB/s（**快 7 倍**）。
  # 但 proot 里的 apt 只单连接，202 MB 要 40 分钟。
  # 所以让 apt 只**解析 URL**（--print-uris，不下载），宿主机用多连接全速下好
  # 放进 _aptcache，apt 再从本地安装。_aptcache 已有 .deb（预烘焙进 APK）则跳过握手。
  if ! ls "$APP_DIR"/_aptcache/*.deb >/dev/null 2>&1; then
    step "计算需要安装的组件"
    apt-get $APT_OPTS install -y --no-install-recommends --print-uris $PKGS 2>/dev/null \
      | grep -oE "https?://[^']+\.deb" | sort -u > "$APP_DIR/_apt-uris.txt"
    ok "清单已生成：$(wc -l < "$APP_DIR/_apt-uris.txt") 个 .deb"

    step "下载运行环境组件（耗时较长，可切到后台）"
    mkdir -p "$APP_DIR/_aptcache"
    for i in $(seq 1 240); do
      [ -f "$APP_DIR/_aptcache/.ready" ] && break
      sleep 10
    done
    [ -f "$APP_DIR/_aptcache/.ready" ] && ok "宿主机下载完成" \
      || step "下载较慢，改用备用方式"
  fi

  # ── 安装 ──────────────────────────────────────────────────────────────
  # ⚠️ 关键教训：**不要**把 .deb 路径直接传给 `apt-get install <路径>`。
  #    实测那样 apt 仍然会联网下载（它把参数当"要装的包"，依赖照样从仓库取），
  #    日志里会看到 "Need to get 199 MB"。
  #    正确做法：把 .deb 放进 **apt 自己的缓存目录** /var/cache/apt/archives/，
  #    apt 会自动复用缓存、只下载缺的那几个。
  if ls "$APP_DIR"/_aptcache/*.deb >/dev/null 2>&1; then
    n=$(ls -1 "$APP_DIR"/_aptcache/*.deb | wc -l)
    step "部署已下载的组件"
    mkdir -p /var/cache/apt/archives/partial
    cp -f "$APP_DIR"/_aptcache/*.deb /var/cache/apt/archives/ 2>/dev/null
    ok "apt 缓存现有 $(ls -1 /var/cache/apt/archives/*.deb 2>/dev/null | wc -l) 个 .deb"
  fi

  step "安装运行环境组件"
  # ⚠️ 两个必须处理的现实问题：
  #
  #  ① 管道会吞掉 apt 的退出码。`apt-get ... | tee | tail -3` 的返回码是
  #     tail 的（永远 0），所以 apt 失败脚本也照样往下走 —— 实测日志里
  #     明明写着 "E: dpkg was interrupted"，下一行却是 "[OK] 基础依赖就绪"，
  #     然后一路错到 uv 报 "No module named 'json'"（Python 被装残了）。
  #     所以必须查 PIPESTATUS[0]。
  #
  #  ② 手机上说杀就杀：用户划掉应用、系统回收内存，都会让 dpkg 停在
  #     "half-configured" 状态。下次启动如果不先修，整个安装永远起不来。
  #     所以失败时先 dpkg --configure -a 修复，再重试一次。
  apt_install() {
    nice -n 10 apt-get $APT_OPTS install -y --no-install-recommends $PKGS 2>&1 \
      | tee -a "$APP_DIR/_bootstrap.log" | tail -3
    return "${PIPESTATUS[0]}"
  }
  if ! apt_install; then
    step "修复上次被中断的安装"
    nice -n 10 dpkg --configure -a 2>&1 | tee -a "$APP_DIR/_bootstrap.log" | tail -3
    apt_install || fail "apt install 失败（已尝试 dpkg --configure -a 修复）"
  fi
  touch "$MARK/base"; ok "基础依赖就绪"
fi

# ── 2a-2. 环境体检（**每次启动都跑**，不受完成标记影响）──────────────────
# ⚠️ 这段一开始写在上面那个 `if [ ! -f "$MARK/base" ]` 里面，结果踩了坑：
#    应用被系统杀掉时 dpkg 停在 half-configured，Python 被装残
#    （import json 都失败）；但 /root/.vs-bootstrap/base 标记早就写下了，
#    下次启动直接跳过整段，修复逻辑永远不会执行，安装就永久卡死。
#    体检必须无条件做 —— 标记只能证明"曾经装过"，不能证明"现在是好的"。
if ! /usr/bin/python3 -c "import json, sys" >/dev/null 2>&1; then
  step "修复运行环境（上次被中断）"
  nice -n 10 dpkg --configure -a 2>&1 | tee -a "$APP_DIR/_bootstrap.log" | tail -5
  if ! /usr/bin/python3 -c "import json" >/dev/null 2>&1; then
    nice -n 10 apt-get $APT_OPTS install -y --reinstall \
        python3 python3-minimal libpython3.12-minimal libpython3.12-stdlib 2>&1 \
        | tee -a "$APP_DIR/_bootstrap.log" | tail -5
  fi
  /usr/bin/python3 -c "import json" >/dev/null 2>&1 \
    || fail "Python 环境损坏且自动修复失败（python3 无法 import json）"
  ok "运行环境已修复"
fi

# ── 2b. 把 apt 的 .deb 缓存留一份到 /app（外部存储，可被打包带走）────────
# 用途：预烘焙。把 /app/_aptcache 里的 .deb 打进 APK 后，新用户装完直接
# 本地安装，跳过整个下载阶段（apt 在 proot 下很慢）。
#
# ⚠️ 条件必须是「archives 里真有 .deb」，不能只判目录在不在。
#    收尾清理会 `rm -rf /var/cache/apt/archives/*.deb`，但**目录还在**，
#    于是第二次开机起这里就成了空转：`cp -n /空目录/*.deb dest 2>/dev/null`
#    的通配符不匹配，cp 返回 1 → 触发 ERR trap → 日志里冒出
#    `[TRAP] 第 195 行失败，退出码 1`。什么都没坏，但排查时极容易被它带偏。
#    顺带也不再每次开机都创建一个空的 _aptcache 目录。
if ls /var/cache/apt/archives/*.deb >/dev/null 2>&1; then
  step "整理安装缓存"
  mkdir -p "$APP_DIR/_aptcache"
  cp -f /var/cache/apt/archives/*.deb "$APP_DIR/_aptcache/" 2>/dev/null || true
  ok "已留存 $(ls -1 "$APP_DIR/_aptcache" 2>/dev/null | wc -l) 个 .deb"
fi
# ── 3. uv ────────────────────────────────────────────────────────────────
if ! command -v uv >/dev/null 2>&1; then
  step "准备运行器"
  # ⚠️ uv 优先用**内置**的那份（assets/vsapp/_uv-aarch64.tar.gz，构建时随
  #    源码一起释放到 /app）。原因：uv 官方只发在 GitHub Releases 上，
  #    而这台设备 github.com 直连是超时的，gh-proxy 兜底也不稳 ——
  #    实测全新安装时正是卡在这一步：
  #      curl: (56) Recv failure: Software caused connection abort
  #      [FAIL] uv 下载失败
  #    装包全离线、却因为一个下载器要联网而失败，说不过去。
  if [ -f "$APP_DIR/_uv-aarch64.tar.gz" ]; then
    tar xzf "$APP_DIR/_uv-aarch64.tar.gz" -C /tmp || fail "内置 uv 解包失败"
    ok "使用内置运行器"
  else
    UV_URL=https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-unknown-linux-gnu.tar.gz
    curl -fsSL --retry 3 --max-time 600 -o /tmp/uv.tar.gz "$UV_URL" \
      || curl -fsSL --retry 3 --max-time 600 -o /tmp/uv.tar.gz \
         "https://gh-proxy.com/$UV_URL" \
      || fail "uv 下载失败"
    tar xzf /tmp/uv.tar.gz -C /tmp || fail "uv 解包失败"
  fi
  find /tmp -name uv -type f -exec cp {} /usr/local/bin/uv \;
  find /tmp -name uvx -type f -exec cp {} /usr/local/bin/uvx \;
  chmod +x /usr/local/bin/uv /usr/local/bin/uvx 2>/dev/null
  command -v uv >/dev/null || fail "uv 安装失败"
  ok "uv 就绪: $(uv --version 2>&1)"
fi

# ── 3b. 编译工具（只在缺少预编译 wheel 时才需要）─────────────────────────
# sphn 是 demucs 的依赖（人声分离/降噪），而它在 PyPI 上**只有 x86_64/mac/win
# 的轮子，没有 linux-aarch64**，所以只能本地用 Rust 编译。
# 一旦把编好的 sphn-*.whl 放进 _wheels，这个判断就直接跳过 —— 最终用户
# 拿到的包里已经带了编好的轮子，永远不会碰 Rust 工具链。
#
# ⚠️ 条件里必须**同时**要求「这次真的要装依赖」。
#    原来只判断 `_wheels/sphn-*.whl` 在不在 —— 而 _wheels 在装完后的收尾
#    清理里会被删掉，于是**第二次开机**开始每次都认定「需要编译器」，
#    重新去清华镜像拉 rustup + 工具链（实测 5-8 分钟、还要联网），
#    装完再被下一次收尾删掉，如此循环。用户看到的就是
#    「重启一下 App，启动要等十分钟」。
#    真正的判据是 venv 里有没有装好（.vs-deps-ok），依赖装好了就不需要编译器。
if [ ! -f "$VENV_DIR/.vs-deps-ok" ] && ! ls "$APP_DIR"/_wheels/sphn-*.whl >/dev/null 2>&1; then
  # ⚠️ apt 里的 rustc/cargo 是 1.75（Ubuntu 24.04），**编不了 sphn**：
  #      error: failed to parse lock file .../Cargo.lock
  #      Caused by: lock file version 4 requires `-Znext-lockfile-bump`
  #    Cargo.lock v4 需要 cargo ≥ 1.78，所以必须用 rustup 装新版工具链。
  #    rustup 走清华镜像（static.rust-lang.org 直连也能通，但镜像快得多）。
  need_rust=no
  if ! command -v cargo >/dev/null 2>&1; then
    need_rust=yes
  else
    cv=$(cargo --version 2>/dev/null | awk '{print $2}')
    cmin=$(printf '%s' "$cv" | cut -d. -f2)
    [ -z "$cmin" ] && cmin=0
    [ "$cmin" -lt 78 ] && need_rust=yes
  fi
  if [ "$need_rust" = "yes" ]; then
    step "准备编译工具（仅开发期需要，约 5-8 分钟）"
    export RUSTUP_HOME=/root/.rustup CARGO_HOME=/root/.cargo
    export RUSTUP_DIST_SERVER=https://mirrors.tuna.tsinghua.edu.cn/rustup
    # ⚠️ 这一步必须放在 rustup 判断**外面**。踩过的坑：原来它嵌在
    #    `if [ ! -x /root/.cargo/bin/cargo ]` 里面，结果 rustup 装好之后的
    #    第二次运行直接跳过整段，libopus-dev 永远装不上，sphn 就一直在
    #    audiopus_sys 那里挂 —— 一个"检查条件写错位置"导致的连环失败。
    DEBIAN_FRONTEND=noninteractive nice -n 10 apt-get install -y --no-install-recommends \
        gcc g++ pkg-config libopus-dev 2>&1 | tail -2
    # libopus-dev 不是可选项：缺它时 audiopus_sys 的 build.rs 会退化成
    # 「用 CMake 现编一份 Opus」，然后失败：
    #   error: failed to run custom build command for `audiopus_sys v0.2.2`
    #   cargo:info=`pkg_config` could not find `Opus`.
    #   cargo:info=Building Opus via CMake.
    # 有了 libopus-dev，pkg-config 直接找到系统库，跳过那一步。
    if [ ! -x /root/.cargo/bin/cargo ]; then
      curl -fsSL --retry 3 --max-time 900 -o /tmp/rustup-init \
        https://mirrors.tuna.tsinghua.edu.cn/rustup/rustup/dist/aarch64-unknown-linux-gnu/rustup-init \
        || fail "rustup-init 下载失败"
      chmod +x /tmp/rustup-init
      /tmp/rustup-init -y --profile minimal --default-toolchain stable --no-modify-path 2>&1 | tail -5 \
        || fail "Rust 工具链安装失败"
    fi
    export PATH="/root/.cargo/bin:$PATH"
  fi
  command -v cargo >/dev/null 2>&1 && ok "Rust 就绪: $(cargo --version 2>&1)" \
    || echo "[WARN] 无 cargo，sphn 可能编不出来"
fi

# ── 4. Python 依赖（最慢的一步）─────────────────────────────────────────
if [ ! -x "$VENV_DIR/bin/python" ] || [ ! -f "$VENV_DIR/.vs-deps-ok" ]; then
  step "安装 AI 运行库（首次很慢，约 10-30 分钟）"
  export UV_NO_PROGRESS=1 UV_LINK_MODE=copy
  export UV_PYTHON_INSTALL_DIR=/root/.uv-python
  # ⚠️ 镜像必须提供 PEP 658 的 `<wheel>.metadata` 边车文件，否则 uv 直接
  #    "Failed to fetch ... .whl.metadata → 404"。实测：
  #      files.pythonhosted.org  ✅ 但只有 44 KB/s（太慢）
  #      mirrors.aliyun.com      ❌ 404     pypi.tuna          ❌ 404
  #      mirrors.ustc.edu.cn     ↪ 302     repo.huaweicloud   ✅ 10 MB/s 但会 429 限流
  #    加了 --frozen 之后 uv 直接用 lock 里的 url+hash，**不再需要 .metadata**，
  #    所以 404 那几家也能用了。即便这样也别只押一个源：华为源下 300 个包
  #    必定触发 429（实测 HTTP 429），而 uv 只会干等不会自己换源
  #    （实测卡死 4 分钟、CPU 0 tick、日志不再增长）。
  export UV_HTTP_TIMEOUT=90
  export UV_CONCURRENT_DOWNLOADS=4
  # ⚠️ 顺序很重要：uv 的下载缓存是**按 index URL 分区**的
  #    （~/.cache/uv/.../<index-hash>/）。换一次源 = 缓存全不命中 = 300 个包
  #    从头再下一遍（实测：换到 aliyun 后 torch/scipy/av 全部重新 Downloading）。
  #    所以把上一轮已经下过大半的源放在**第一位**，后面两个只做兜底。
  INDEXES="https://repo.huaweicloud.com/repository/pypi/simple
https://mirrors.aliyun.com/pypi/simple/
https://pypi.tuna.tsinghua.edu.cn/simple"
  # ⚠️ github.com 在这台设备上直连超时（HTTP 000）。uv 默认从 GitHub Releases
  #    拉 python-build-standalone，会卡死在 Downloading cpython-3.11.x。
  #    两条路：① 走 gh-proxy 镜像；② 直接用 rootfs 里的系统 python3（apt 装的 3.12，
  #    满足 requires-python ">=3.11"）。优先 ②，零下载。
  export UV_PYTHON_INSTALL_MIRROR="https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download"
  export UV_PYTHON_PREFERENCE=only-system
  # ⚠️ /app 在 FUSE（/sdcard）上，**不支持符号链接**。venv 里 bin/python 是指向
  #    /usr/bin/python3 的软链，放 /app/.venv 会直接
  #    "failed to symlink ... Permission denied (os error 13)"。
  #    所以 venv 必须落在 rootfs（app 私有 ext4）里。
  export UV_PROJECT_ENVIRONMENT="$VENV_DIR"
  cd "$APP_DIR" || fail "找不到 $APP_DIR"
  if [ -x /usr/bin/python3 ]; then
    ok "使用系统 Python: $(/usr/bin/python3 -V 2>&1)"
    PYARG="--python /usr/bin/python3"
  else
    PYARG="--python 3.11"
  fi
  # ⚠️ 必须 --frozen：/app 在 FUSE 上，uv.lock 是宿主机（uid 2000）拷进去的，
  #    应用身份写不了 → "failed to write to file /app/uv.lock: Permission denied"。
  #    --frozen 让 uv 直接用现成的 lock，不重解析也不回写。
  UV_OK=no
  IDX_N=0
  # ⚠️ --find-links 是这台设备上唯一能跑通的办法，原因值得记下来：
  #    uv 下**大文件**（torch 97MB / av 36MB / scipy 32MB / spacy 31MB）时会
  #    卡在重试循环里出不来 —— 日志反复刷 "Downloading X" 却不出现 "Downloaded"，
  #    磁盘 0 增长、CPU 0 tick，换 huawei / aliyun 两个源症状一模一样。
  #    而**同一条网线、同一个 URL，curl 拉那个 102MB 的 torch wheel 只要 6.9 秒**
  #    （15 MB/s）。所以不是网络、不是镜像，是 uv 自己的 HTTP 栈在这台机器上
  #    处理大响应有问题。
  #    绕法：宿主机用 curl 把 283 个 wheel 全下好（642MB，3 分钟），推进
  #    /app/_wheels，uv 只从本地目录取，一个字节都不用自己下。
  FL=""
  if [ -d "$APP_DIR/_wheels" ]; then
    n_w=$(ls -1 "$APP_DIR/_wheels"/*.whl 2>/dev/null | wc -l)
    [ "$n_w" -gt 0 ] && {
      FL="--find-links $APP_DIR/_wheels"
      ok "已内置 $n_w 个离线 wheel，优先本地安装"
    }
  fi
  # ⚠️ --frozen 时 uv **完全不看 --find-links**：lock 里把每个 wheel 的 URL 钉死
  #    了，uv 直奔那个 URL 去下载（实测加了 find-links 它照样 "Downloading torch"）。
  #    想强制走本地必须配 --no-index（不给它任何远端源可用）。
  #    所以顺序是：先在**全离线**下装（这正是最终要交付的形态：不联网也能装），
  #    实在缺包才退回到联网源。
  if [ -n "$FL" ]; then
    step "安装 AI 运行库（使用内置组件，无需联网）"
    # ⚠️ --no-install-project 是必需的：本项目（omnivoice）要作为 wheel 构建，
    #    而构建它需要 hatchling 这个 build backend —— 它不在依赖树里，
    #    离线装时必然报 "No solution found when resolving: `hatchling`"。
    #    后端是用 `python -m uvicorn --app-dir backend` 从 /app 直接跑的
    #    （sys.path 里有 /app 和 /app/backend），根本不需要把项目装进 venv。
    echo "[INFO] 尝试全离线安装: uv sync --offline --no-index $FL --no-install-project" >> "$APP_DIR/_bootstrap.log"
    # ⚠️ 这里**绝对不能加 --frozen**，三个坑连起来是这样：
    #    ① --frozen 时 uv 只认 lock 里钉死的 wheel URL，--find-links 形同废纸
    #       （实测：加了 find-links，它照样 "Downloading torch"）；
    #    ② 加 --offline 逼它用本地，它报 "requested data wasn't found in the cache"；
    #    ③ 把 lock 里的 URL 改写成 file:///app/_wheels/... 想让它是本地文件，
    #       uv 直接拒绝："URL scheme is not allowed"（lock 只收 http/https）。
    #    所以只能**放弃 --frozen**，让 uv 拿 --find-links 里的本地 wheel 重新解析。
    #    代价是它会回写 uv.lock，所以那个文件必须是可写的（见下面 chmod）。
    chmod 666 "$APP_DIR/uv.lock" 2>/dev/null
    nice -n 10 uv sync --offline --no-index $FL --no-install-project $PYARG --no-dev 2>&1 | tee -a "$APP_DIR/_bootstrap.log" | tail -3
    if [ "${PIPESTATUS[0]}" = "0" ]; then UV_OK=yes; fi
    [ "$UV_OK" = "yes" ] && ok "内置组件安装完成（未联网）"
  fi
  for IDX in $INDEXES; do
    [ "$UV_OK" = "yes" ] && break
    IDX_N=$((IDX_N + 1))
    export UV_DEFAULT_INDEX="$IDX"
    # ⚠️ [STEP] 开头的行会被 BackendService 抓去**直接显示在用户界面底部浮层**上，
    #    所以这里只能说人话，不能把镜像 URL 之类的内部细节甩给用户看。
    #    实际用的是哪个源，写进日志文件就够了。
    step "补齐剩余组件（这一步较慢）"
    echo "[INFO] uv sync 源 #$IDX_N: $IDX  find-links=${FL:-无}（离线装缺包时的兜底）" >> "$APP_DIR/_bootstrap.log"
    nice -n 10 uv sync $FL --no-install-project $PYARG --no-dev 2>&1 | tee -a "$APP_DIR/_bootstrap.log" | tail -3
    if [ "${PIPESTATUS[0]}" = "0" ]; then UV_OK=yes; break; fi
    echo "[WARN] 源 #$IDX_N 失败，换下一个" >> "$APP_DIR/_bootstrap.log"
    step "下载源不稳定，换用备用源重试"
  done
  export UV_DEFAULT_INDEX=https://repo.huaweicloud.com/repository/pypi/simple
  # ⚠️ 必须查 PIPESTATUS：管道末端的 tail 永远返回 0，
  #    不查的话 uv 失败也会被当成 "[OK] Python 依赖就绪"。
  if [ "$UV_OK" != "yes" ] || [ ! -x "$VENV_DIR/bin/python" ]; then
    tail -25 "$APP_DIR/_bootstrap.log"
    fail "uv sync 失败（3 个源都试过了，见上方日志）"
  fi
  # ⚠️ 光有 bin/python 不代表依赖装好了：上一轮失败留下的空 venv 会让
  #    `[ -x ... ]` 为真，脚本直接跳过 sync 去启动后端 → "No module named uvicorn"。
  #    所以用显式标记文件记录"依赖真的装完了"。
  "$VENV_DIR/bin/python" -c "import uvicorn, fastapi" 2>/dev/null \
    || fail "依赖装完了但 import uvicorn/fastapi 失败"
  touch "$VENV_DIR/.vs-deps-ok"
  ok "Python 依赖就绪"

  # ── 回收「从源码编出来的」wheel ──────────────────────────────────────
  # sphn 这类包 PyPI 上没有 aarch64 轮子，是刚才用 Rust 现场编的。把编好的
  # wheel 收回 _wheels，下次就命中本地、不需要再编：
  #   · 开发期：重装不用等编译
  #   · 交付期：用 scripts/bake-runtime.sh 打进 APK，最终用户机器上
  #     连 Rust 都不用装（bootstrap 开头那句 `ls _wheels/sphn-*.whl` 会直接跳过）
  for w in sphn; do
    if ! ls "$APP_DIR"/_wheels/"$w"-*.whl >/dev/null 2>&1; then
      found=$(find /root/.cache/uv -name "$w-*.whl" 2>/dev/null | head -1)
      if [ -n "$found" ]; then
        cp "$found" "$APP_DIR/_wheels/" && ok "已回收编译产物: $(basename "$found")"
      fi
    fi
  done
fi

# ── 4a-2. 统一文件权限 ───────────────────────────────────────────────────
# ⚠️ 容器里 cp 出来的文件是 0600（app 私有 umask），而 `/sdcard` 那边
#    宿主机是用 shell（uid 2000，只在 ext_data_rw 组里）读的 —— 600 的文件
#    它**读不到**，搬运到开发机时会静默少文件（实测 305 个只搬过去 304 个，
#    丢的正好是编了 11 分钟才得到的 sphn wheel）。
#    统一放开到 0644/0755，让宿主机能取走。
#
# ⚠️ 必须逐个判断目录存不存在，不能让通配符空着展开。
#    收尾清理会删掉 _wheels / _aptcache，于是这里变成
#      chmod 644 /app/_aptcache/*   → 通配符不匹配 → chmod 返回 1
#    触发 ERR trap，日志里刷出三行吓人的
#      [TRAP] 第 416/417/418 行失败，退出码 1
#    虽然脚本没 set -e 还能往下走，但排查时非常容易被这几行带偏。
for d in _wheels _aptcache; do
  [ -d "$APP_DIR/$d" ] || continue
  chmod -R a+rX "$APP_DIR/$d" 2>/dev/null || true
  find "$APP_DIR/$d" -maxdepth 1 -type f -exec chmod 644 {} + 2>/dev/null || true
done

# ── 4b. 收尾清理 ─────────────────────────────────────────────────────────
# 装完之后有一大堆东西纯粹是"过程产物"，留着只占空间。实测这台机器上
# VoiceStudio 一度占到 9.45 GB，其中约 3.5 GB 是这些：
#   · rustup 工具链 + cargo registry  → 只在编 sphn 那一次用得上（约 1.5 GB）
#   · uv 下载缓存                     → 装完就没用了（约 1 GB）
#   · _wheels / _aptcache             → 只需保留到 venv 装完（约 1.1 GB）
#
# 分两段，因为「开发机」和「最终用户」需要的保留物不一样：
step "清理安装过程文件"
# (a) 编译工具链和下载缓存：**任何情况下**都不再需要 —— sphn 编好之后
#     会被回收成 wheel 放进 _wheels，以后不会再编。
rm -rf /root/.rustup /root/.cargo /root/.cache/uv /root/.cache/pip 2>/dev/null
apt-get clean 2>/dev/null
rm -rf /var/cache/apt/archives/*.deb 2>/dev/null
ok "已释放编译工具链与下载缓存"
# (b) _wheels / _aptcache：最终用户装完就没用了；但开发机要拿它们
#     打包进 APK（scripts/bake-runtime.sh），所以用 _keep_payload 标记保留。
if [ -f "$APP_DIR/_keep_payload" ]; then
  echo "[INFO] 检测到 _keep_payload，保留 _wheels / _aptcache 供打包"
else
  rm -rf "$APP_DIR/_wheels" "$APP_DIR/_aptcache" 2>/dev/null
  ok "已释放离线安装包（venv 已装好，不再需要）"
fi

# ── 4c. 体积自检 ─────────────────────────────────────────────────────────
# 把各部分占用写进日志（日志在外部目录，宿主机读得到），
# 免得"占了 9 个 G"这种事只能靠用户在设置里看到才发现。
# ⚠️ 只在**首次安装**时跑一次，绝不能每次开机都跑。
#    踩过的坑：这段原来是无条件执行的，于是每次启动都要对 4.8 GB 的
#    rootfs 做 `du -sh /`。在 proot 下每一个系统调用都要经 ptrace，
#    实测光 `du -sh /root/.venv` 一个目录就要一分多钟，整个自检十几分钟；
#    而后端启动（下面的第 5 步）写在它**后面**，表现就是
#    「重启 App 后一直转圈，日志停在体积自检那一行不再增长」。
#    诊断信息永远不该挡住启动路径 —— 所以用标记文件锁成一次性的。
if [ ! -f "$MARK/selfcheck" ]; then
  touch "$MARK/selfcheck"
  # ⚠️ 放**后台**跑：诊断信息永远不能挡在启动路径前面。
  #    只靠标记文件还不够 —— 装完后的第一次重启仍然要跑一遍，
  #    用户还是得干等十几分钟。丢到后台就一劳永逸了。
  (
    echo "--------------- 体积自检 $(date -u +%H:%M:%S) ---------------"
    for p in /root/.venv /root/.rustup /root/.cargo /root/.cache/uv \
             /usr /opt /var/cache/apt "$APP_DIR/_wheels" "$APP_DIR/_aptcache"; do
      [ -e "$p" ] && printf '%-28s %s\n' "$p" "$(du -sh "$p" 2>/dev/null | cut -f1)"
    done
    echo "rootfs 合计: $(du -sh / 2>/dev/null | tail -1 | cut -f1)"
  ) >> "$APP_DIR/_bootstrap.log" 2>&1 &
fi

# ── 5. 启动后端 ──────────────────────────────────────────────────────────
step "启动引擎"
cd "$APP_DIR" || fail "找不到 $APP_DIR"
export OMNIVOICE_BIND_HOST=127.0.0.1
export OMNIVOICE_PORT="$BE_PORT"
export CUDA_VISIBLE_DEVICES=""
export PYTHONUNBUFFERED=1 PYTHONUTF8=1

# ⚠️ 这台设备上 huggingface.co 直连**超时**，hf-mirror.com 才通（实测 6–8 MB/s）。
#    huggingface_hub 认 HF_ENDPOINT，不设的话后端所有模型下载都会失败。
export HF_ENDPOINT=https://hf-mirror.com
export HF_HUB_DOWNLOAD_TIMEOUT=60
# pip / uv 也走国内源，避免 pypi 慢
export PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
export UV_DEFAULT_INDEX=https://repo.huaweicloud.com/repository/pypi/simple

touch /root/.vs-bootstrap-done
exec "$VENV_DIR/bin/python" -m uvicorn main:app \
  --app-dir backend --host 127.0.0.1 --port "$BE_PORT"

# VoiceStudio-Native 端口 / 热更 / 密钥

## 端口（都已固定）
| 端口 | 用途 |
|---|---|
| **127.0.0.1:3900** | 原生壳。WebView 指向这里；被占用则顺延 3901…3919 |
| **127.0.0.1:3901** | 真后端（Python/uvicorn，跑在 proot 的 Ubuntu 里）|

壳收到 API 请求后**反代**到 3901；后端没起来时先由内置桩顶着，界面立刻可见。

## 热更（改完强杀重启即可，不必重装 APK）
路径：`/sdcard/Android/data/sh.voicestudio.app/files/`

| 位置 | 作用 |
|---|---|
| `webui/` | 覆盖前端页面（放同名文件即覆盖 APK 内置的） |
| `api-stubs/<路径转下划线>.json` | 直接作为该接口的响应体，例 `models_install_status.json` |
| `bootstrap.sh` | 后端起环境脚本（改它不用重装） |
| `vsapp/` | VoiceStudio 后端源码（bind 到 rootfs 的 /app） |
| `models/` | ONNX 模型 |

重启：`am force-stop sh.voicestudio.app && am start -n sh.voicestudio.app/.MainActivity`

## 数据位置（卸载即全部清除，无残留）
所有自带/生成的数据都在**应用专属目录**内：
- 私有：`/data/user/0/sh.voicestudio.app/files/{rootfs,runtime}`
- 专属外部：`/sdcard/Android/data/sh.voicestudio.app/files/`
卸载 App 时系统会一并删除，**不会在 /sdcard 留下任何东西**。

## 签名密钥（丢了要卸载重装、数据全没）
备份：`/sdcard/Download/VoiceStudio-Native-backup/debug.keystore`
工作区原件：`voicestudio-native/keys/debug.keystore`
sha256: 71ad4c3669ab66c001cbf055994b196cca7c0d021eff7be3701a7a6b65e98620
alias `androiddebugkey` / storepass & keypass `android`

## 其它
- 包名 `sh.voicestudio.app`
- 构建 `voicestudio-native/scripts/build-apk-ondevice.sh`（无 Gradle）
- 安装前必须拷到 `/data/local/tmp/`（`/sdcard` 直装会被 system_server 拒绝）

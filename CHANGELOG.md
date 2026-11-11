# Changelog

## v1.4

**应用**

- 指定输出目录时**保留拖入文件夹的子目录结构**，不再出现同名文件互相覆盖（`albumA/x.ncm` → `输出目录/albumA/x.mp3`）
- 整批完成时播放提示音；窗口在后台时图标弹跳提醒
- 日志同时落盘到 `~/Library/Logs/ncmdump-gui.log`，超过 4 MB 自动清空
- 记住窗口尺寸
- 拖入不含 ncm 的文件夹时，提示「已跳过 N 个其它文件」
- 错误信息中文化：`Not netease protected file` → 「不是有效的 ncm 文件（可能已损坏，或不是网易云下载的）」
- 状态栏显示当前正在转换的文件名
- 转换进行中禁用「清空」，避免进度统计错乱

**构建**

- 内核下载增加 **SHA256 校验**，被篡改或上游重新打包会直接失败
- 版本号由 `APP_VERSION` 控制（默认 1.4），不再写死在脚本里
- 保持 universal2（arm64 + x86_64），内核同样 universal

**CI**

- `.github/workflows/ci.yml`：push / PR 自动在 macOS runner 构建并冒烟检查
- `.github/workflows/release.yml`：推 `v*` 标签自动打包并发布 Release

## v1.3

首个公开可下载版本。

- macOS 12+，universal2
- 拖拽批量转换、失败自动重试、可选删除源文件、自选输出目录、批量进度条
- 内置 ncmdump 1.5.0 静态版，无需 Homebrew / ffmpeg
- 以产物存在性判定成功，避免误删源文件

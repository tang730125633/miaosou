# 秒搜 Miaosou

一个轻量、原生的 macOS 应用与文件启动器，用来替代经常漏结果的 Spotlight 搜索框。

## 当前能力

- `⌘ Space` 显示或隐藏搜索框。
- 搜索框为空时，按 macOS 的应用使用次数与最后使用时间显示“推荐打开”，并排除当前正在使用的应用。
- 直接扫描 `/Applications`、`/System/Applications` 和用户应用目录，不依赖 Spotlight 查找 App。
- 后台直接整理桌面、文稿、下载、影片、音乐、图片和 iCloud Drive 的文件名与文件夹名。
- 同时用 macOS 元数据搜索补充结果；应用始终优先。
- `↑/↓` 选择，`↩` 打开，`⌘↩` 在访达中显示，`Esc` 清空或隐藏。
- 无网络请求、无第三方依赖、无自建数据库。
- 推荐统计来自本机 Spotlight 元数据，只读取使用次数和最后使用时间，不上传。

## 安装

要求 macOS 13 或更新版本，以及 Apple Command Line Tools。

1. 在系统设置的“键盘 → 键盘快捷键 → Spotlight”关闭“显示 Spotlight 搜索”。
2. 双击 `build.command`。

脚本会编译、自检、本地签名、安装到 `/Applications/秒搜.app`，登记登录项并打开应用。

## 开发与验证

```bash
./build.command
/Applications/秒搜.app/Contents/MacOS/秒搜 --self-check
codesign --verify --deep --strict /Applications/秒搜.app
```

## 当前边界

- 只搜索名称，不搜索文件正文。
- 默认检索 macOS 标准用户目录；自定义检索目录留给下一阶段。
- 当前使用有界的内存索引，不保存搜索历史。
- 部分应用没有 macOS 使用统计时，只能用“当前正在运行”作为推荐兜底。

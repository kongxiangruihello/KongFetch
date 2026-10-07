# KongFetch

原生 macOS 文件搜索与预览应用，支持 macOS 13+、Apple 芯片与 Intel。
主窗口为 750×474 点，提供菜单栏入口、自定义组合快捷键和双 Control 唤起。

## 下载与安装

当前版本：**3.2**。

- [下载 DMG 安装包](https://github.com/kongxiangruihello/KongFetch/raw/refs/heads/main/dist/KongFetch-3.2-Mac.dmg)
- [下载 ZIP 安装包](https://github.com/kongxiangruihello/KongFetch/raw/refs/heads/main/dist/KongFetch-3.2-Mac.zip)
- [SHA-256 校验值](dist/KongFetch-3.2-SHA256.txt)

退出旧版，把 KongFetch.app 拖入 Applications，再打开。应用运行时快捷键生效，可在设置中启用登录启动。

安装包使用本地 ad hoc 签名，未使用 Developer ID 或 Apple 公证。更新后双 Control 可能需要重新确认输入监控权限；如果无反应，请在系统设置的输入监控中移除旧条目，再添加 `/Applications/KongFetch.app` 并允许，退出后重新打开。

## 3.2 新增

- 漏搜诊断与目标附近目录修复。
- 引号短语、排除词、扩展名组合搜索，例如 `ext:pdf "年度合同" -草稿`。
- 可搜索的 ⌘K 操作面板，显示快捷键并保留原有操作。
- ⌘→ 在选中文件夹继续搜索，⌘← 恢复原搜索、选择和滚动位置。
- OCR文字选择复制、TXT导出及选中文字搜索。
- 按实际内容查找重复文件，预览核对，支持取消。
- 中文输入保护、⌘1–9打开结果及后台更新位置保持。
- 本机剪贴板历史：文字、图片、文件引用、搜索、固定、暂停、清空；⌃⌥V全局打开，首次手动启用记录。跳过敏感标记与排除应用。

## 功能

- 精确名称、模糊名称、名称及路径、中文拼音与缩写搜索，结果反馈、首选结果、别名和常用搜索。
- Quick Look 预览、访达定位、收藏、多选和标准文件拖拽。
- 持久化 OCR 目录、逐文件管理、暂停与重试，文件新增、修改、移动后自动更新。
- 图片关键词框、扫描 PDF 页码定位，以及上一处 / 下一处命中。
- ZIP 内部名称与路径搜索，按需解压预览和打开。
- 批量重命名预览、整批撤销、冲突保护和中断恢复。
- GitHub 更新检查、校验下载、旧版备份和回退。
- 自然语言筛选，例如“最近一周的 PDF”“大于100MB的视频”“标签:工作 合同”。
- 重命名、移动、移到废纸篓及撤销；访达文字标签与颜色。
- 双 Control 唤起诊断，分别检查收到事件、窗口可见和输入焦点。
- 名称索引增量更新、自动节能、后台进度和资源监测。
- 每个操作可设置应用内或全局快捷键，检查冲突；保留唤起及目录快捷键。

新增功能从右下角 **操作 ⌘K** 进入。OCR 需先选择文件夹建立索引，然后顶部选择“文件内容”。识别文字保存在本机，原文件不修改。

完整说明和限制见 [3.2 使用说明](docs/开始使用-3.2.txt)。OCR 每文件最多 100 MB、PDF 前 30 页、50 万字符；云端未下载文件会跳过。所选目录在启动与文件变化后自动检查。撤销记录最多 20 条，仅保留在本次运行中。

## 默认全局操作快捷键

| 组合键 | 操作 |
| --- | --- |
| Control + Option + 2 | 名称 / 内容搜索 |
| Control + Option + F | 名称匹配精度 |
| Control + Option + O | OCR 管理 |
| Control + Option + Z | 压缩包搜索 |
| Control + Option + R | 批量重命名 |
| Control + Option + U | 检查更新 |

在 `操作→操作快捷键` 中可修改组合和范围，也可为聚焦搜索、操作菜单及撤销启用全局触发。

## 从源码构建

需要 macOS 和 Apple Command Line Tools，使用系统 Swift 编译器，不依赖第三方包。

```sh
bash scripts/build.sh
```

输出为 `build/KongFetch.app`，同时编译 arm64 与 x86_64，再合并为通用应用并本地签名。

```sh
bash scripts/package.sh
```

根据 `app/Info.plist` 的版本生成 `build/dist` 中的 DMG、ZIP 和校验文件。

## 验证

```sh
bash scripts/check.sh
```

GUI 检查应在已登录的 macOS 桌面会话中运行，使用临时文件验证搜索、预览、设置升级、文件撤销、真实中文图片和扫描 PDF OCR、标签、筛选及 Control 双击识别。

3.2 已在 Apple 芯片上通过功能及界面检查。Intel 编译通过，尚未在 Intel 实机运行。系统权限及实体双 Control 跨应用唤起需在安装版本上手动确认。

## 源码

`Sources/main.swift` 为应用与搜索逻辑，`Sources/Features30.swift` 包含 OCR、自然语言筛选、文件操作和资源策略，`Sources/Features31.swift` 包含 OCR 管理、定位、压缩包、批量重命名、更新与操作快捷键。只使用 macOS 系统框架。

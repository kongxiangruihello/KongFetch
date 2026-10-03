# KongFetch

原生 macOS 文件搜索与预览应用，支持 macOS 13+、Apple 芯片与 Intel。
主窗口为 750×474 点，提供菜单栏入口、自定义组合快捷键和双 Control 唤起。

## 下载与安装

当前版本：**3.0**。

- [下载 DMG 安装包](https://github.com/kongxiangruihello/KongFetch/raw/refs/heads/main/dist/KongFetch-3.0-Mac.dmg)
- [下载 ZIP 安装包](https://github.com/kongxiangruihello/KongFetch/raw/refs/heads/main/dist/KongFetch-3.0-Mac.zip)
- [SHA-256 校验值](dist/KongFetch-3.0-SHA256.txt)

退出旧版，把 KongFetch.app 拖入 Applications，再打开。应用运行时快捷键生效，可在设置中启用登录启动。

安装包使用本地 ad hoc 签名，未使用 Developer ID 或 Apple 公证。更新后双 Control 可能需要重新确认输入监控权限；如果无反应，请在系统设置的输入监控中移除旧条目，再添加 `/Applications/KongFetch.app` 并允许，退出后重新打开。

## 功能

- 文件名、路径、中文拼音与缩写搜索，结果反馈、首选结果、别名和常用搜索。
- Quick Look 预览、访达定位、收藏、多选和标准文件拖拽。
- 图片与扫描 PDF 本地 OCR，正文摘要和关键词命中提示。
- 自然语言筛选，例如“最近一周的 PDF”“大于100MB的视频”“标签:工作 合同”。
- 重命名、移动、移到废纸篓及撤销；访达文字标签与颜色。
- 双 Control 唤起诊断，分别检查收到事件、窗口可见和输入焦点。
- 名称索引增量更新、自动节能、后台进度和资源监测。
- 自定义全局与目录快捷键、登录启动、设置备份与恢复。

新增功能从右下角 **操作 ⌘K** 进入。OCR 需先选择文件夹建立索引，然后顶部选择“文件内容”。识别文字保存在本机，原文件不修改。

完整说明和限制见 [3.0 使用说明](docs/开始使用-3.0.txt)。OCR 每文件最多 100 MB、PDF 前 30 页、50 万字符；云端未下载文件会跳过。文件修改或移动后需重新建立 OCR 索引。撤销记录最多 20 条，仅保留在本次运行中。

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

3.0 已在 Apple 芯片上通过功能及界面检查。Intel 编译通过，尚未在 Intel 实机运行。系统权限及实体双 Control 跨应用唤起需在安装版本上手动确认。

## 源码

`Sources/main.swift` 为应用与搜索逻辑，`Sources/Features30.swift` 包含 OCR、自然语言筛选、文件操作和资源策略。只使用 macOS 系统框架。

# KongFetchCore

KongFetch 的搜索引擎核心库，不依赖 AppKit，可独立编译和测试。这是"下一版"第一阶段的成果，应用界面尚未接入。

## 内容

| 模块 | 作用 |
| --- | --- |
| `NameIndex` | 名称索引。列式存储：所有名称存放在同一块字节数组中，父目录、类型、折叠后的检索键、扩展名边界、拼音都是并行数组，搜索时多核扫描，不为每个文件创建对象。 |
| `ExclusionRules` | 可配置的排除规则。默认只按精确路径排除 `~/Library`，名称排除仅限 `node_modules`、`.git`、`DerivedData`、`.Trash`；用户自己命名为 `build`、`Library` 的文件夹会被收录（3.2 会漏掉）。 |
| `NameIndex.apply` | 增量更新。每个变动只重读其所在文件夹并比对，耗时取决于涉及的文件夹，而不是索引大小。 |
| `FileChangeWatcher` | FSEvents 监听，可从保存的事件 ID 续接：应用未运行期间的改动会在下次启动时补上，不必整盘重扫。 |
| `NameIndex.save/load` | 二进制索引文件，按列整块读写，替代 3.2 的 JSON 路径数组。 |
| `SearchSession` | 边输入边搜索。新查询只是在旧查询后追加字符或词时，只在上次结果中重新打分。 |
| `KongFetchLegacy32` | 3.2 匹配与扫描代码的原样副本，仅用作测试和基准的对照。 |

## 与 3.2 的一致性

三种精度（精确名称、模糊名称、名称及路径）的打分与 3.2 逐项一致，由 `MatchingParityTests` 对每个文件、每条查询逐一比对验证。

## 测试与基准（需在 Mac 上运行）

```sh
cd Core
swift test                                  # 全部测试
swift run -c release kfbench synth /tmp/tree 300000
swift run -c release kfbench new /tmp/tree     # 新引擎
swift run -c release kfbench legacy /tmp/tree  # 3.2 对照
```

`scripts/mac-test.sh test|bench` 会拉取本分支最新代码并把输出写入 `Core/.logs/`。

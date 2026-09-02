# 设置页设计与实现

Pasteory 的设置页使用左侧导航和右侧分组表单，结构与资料库保持一致。左侧负责切换页面，右侧只展示当前页面的标题、说明和配置内容。

## 页面分组

- 基础设置：通用、采集与隐私。
- 交互与内容：快捷键、打开方式、链接解析。
- 数据与支持：存储与清理、高级诊断、关于。

新增设置页时，先放进含义最接近的现有分组。只有出现一组无法归入现有类别的配置时，才新增分组，避免侧边栏越来越碎。

## 主题色

- 侧边栏选中项、主要按钮、快捷面板标签、资料库选中态、置顶背景和内容类型标签都直接读取当前主题色。
- 主题变化要在已经打开的窗口里立即生效，不能要求用户关闭窗口或重启 Pasteory。
- 警告、错误、收藏星标和代码语法等有固定含义的颜色不跟随主题变化。

## 按钮布局

- 同一行内的操作按钮尽量靠右排列。左侧留给字段名称、状态说明和帮助文字。
- 一组按钮使用同一个右对齐容器。普通操作放在前面，破坏性操作放在最后，例如“重启 Pasteory”在左，“退出 Pasteory”在右。
- 列表项里的行内操作放在内容末尾。应用名称、图标等信息留在左侧，“移除”等按钮放在右侧。
- `Toggle`、`Picker`、快捷键录制器等表单控件按系统习惯排布，不为了追求右对齐而改变控件结构。
- 需要独占一行的说明文字保持左对齐，不能和按钮挤在同一行。
- 主题色一类需要快速比较的选项可以并排展示，但整组选项仍放在字段名称右侧。当前选中的颜色必须有勾选状态，不能只依赖颜色差异。
- 应用选择器、文件后缀和删除按钮属于同一条规则时，后缀放在左侧，应用选择器和删除按钮靠右。删除按钮固定放在这一行的最右侧。

`SettingsView` 中的独立操作统一通过 `settingsActionRow` 排列。布尔设置统一使用 `SettingsSwitchRow`：名称或说明在左，macOS switch 在右，不使用 checkbox。新增按钮时先判断它是否与左侧信息属于同一行；如果不是，就放进右对齐容器。

## 当前页面

- 通用：主题色、登录时启动、运行状态、重启和退出。
- 打开方式：指定网页浏览器、系统图片预览器、代码编辑器和文件后缀规则。
- 采集与隐私：检测频率、来源详情开关、排除应用。
- 链接解析：网页标题解析、失败记录、兜底规则、Pasteory WebKit 登录会话和 Chrome 连接。
- 快捷键：全局唤起、空格打开、搜索焦点、各操作快捷键和恢复默认值。
- 存储与清理：自动归档、导入和导出备份。
- 高级诊断：辅助功能权限、连接诊断和搜索索引。
- 关于：应用图标、当前版本和产品说明。

## 代码位置

- `Sources/Pasteory/SettingsView.swift`：设置页结构、按钮布局和各项交互。
- `Sources/Pasteory/LinkResolutionSettingsView.swift`：链接解析设置及其行内操作。
- `Sources/Pasteory/OpenBehaviorSettingsView.swift`：网页、图片、代码和文件的打开方式。
- `Sources/Pasteory/AppSettings.swift`：设置数据与快捷键配置。
- `Sources/Pasteory/AppCoordinator.swift`：设置窗口的创建和调试截图入口。

## 验证

使用隔离数据打开设置页截图，不读取真实剪贴板：

```bash
QA_DATA_ROOT=$(mktemp -d /tmp/pasteory-settings-qa.XXXXXX)
arch -arm64 /usr/bin/swift build --arch arm64
.build/arm64-apple-macosx/debug/Pasteory \
  --debug-data-root "$QA_DATA_ROOT" \
  --debug-open-settings \
  --debug-ui-qa \
  --debug-disable-monitor \
  --debug-disable-hotkey \
  --debug-snapshot-path "$QA_DATA_ROOT/settings.png"
```

截图检查侧边栏分组是否清楚、同行按钮是否靠右、说明文字是否完整，以及切换主题后选中项和内容标签是否同步更新。

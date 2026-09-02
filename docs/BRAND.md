# Pasteory 品牌与图标

**Pasteory learns from what you copied.**

从复制过的内容里，学会你做事的习惯。

## 名字

Pasteory 把 Paste、Past 和 Story 放在同一个名字里。每次复制都会留下一个过去的片段；片段积累起来，才看得出用户做事的习惯。产品利用这些习惯，帮助用户更快完成下一次操作。

## 图标

图标以 Pasteory 的首字母 P 为主体。三枚大小和轮廓完全相同的 P 等距叠放，表示不断积累的复制历史；最前面的暖白色 P 带有金属夹扣，既是字母，也是剪贴板。后两层只露出窄边，让人能看出历史层次，又不会挤占主体。

三层共同把 Past、History 和 Story 放在同一个符号里：过去留下记录，层叠形成历史，积累起来才成为故事。正式构建直接读取确认后的品牌准稿，避免再次生成时出现造型或材质漂移。

## 菜单栏

菜单栏只有 18 pt，完整保留三张页面和三个圆点会显得拥挤。这里使用三层叠放的单色 P：仍然保留“历史页面”的层次，但去掉颜色和时间点。图标使用 macOS Template Image，会自动适配浅色、深色和高亮状态。

正式包内包含 `18 × 18` 与 `36 × 36` 两档透明 PNG。应用加载后将它们标记为 Template Image，菜单栏负责着色，PNG 本身不带白底或深色底。

## 文件

- `brand/pasteory-app-icon.png`：应用图标预览。
- `brand/pasteory-app-icon-64.png`、`brand/pasteory-app-icon-32.png`：小尺寸检查图。
- `brand/pasteory-menu-bar-preview.png`：菜单栏浅色、深色模式预览。
- `brand/pasteory-menu-bar-icon.png`、`brand/pasteory-menu-bar-icon@2x.png`：菜单栏透明资源检查图。
- `brand/pasteory-icon-concept.png`：图像生成阶段的方向稿。
- `../scripts/generate_icon.swift`：构建时优先读取品牌准稿，并生成应用图标资源。

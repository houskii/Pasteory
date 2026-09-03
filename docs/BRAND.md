# Pasteory 品牌与图标

**Pasteory learns from what you copied.**

从复制过的内容里，学会你做事的习惯。

## 名字

Pasteory 把 Paste、Past 和 Story 放在同一个名字里。每次复制都会留下一个过去的片段；片段积累起来，才看得出用户做事的习惯。产品利用这些习惯，帮助用户更快完成下一次操作。

## 图标

图标以 Pasteory 的首字母 P 为主体。三枚大小和轮廓完全相同的 P 等距叠放，表示不断积累的复制历史；最前面的暖白色 P 带有金属夹扣，既是字母，也是剪贴板。后两层只露出窄边，让人能看出历史层次，又不会挤占主体。

三层共同把 Past、History 和 Story 放在同一个符号里：过去留下记录，层叠形成历史，积累起来才成为故事。正式构建直接读取确认后的品牌准稿，避免再次生成时出现造型或材质漂移。

## 菜单栏

菜单栏图标直接从确认后的应用图标准稿中提取最前层 P 和剪贴板夹扣的像素轮廓，再把同一个 P 轮廓等距叠放三次。字腔的位置、大小和弧线都跟随准稿，不再维护另一套手绘坐标；夹扣只属于最前层，不随后两层重复。这里只去掉背景、颜色、材质和阴影。图标使用 macOS Template Image，会自动适配浅色、深色和高亮状态。

正式包内包含 `18 × 18` 与 `36 × 36` 两档透明 PNG。应用加载后将它们标记为 Template Image，菜单栏负责着色，PNG 本身不带白底或深色底。

两档资源必须使用相同的点坐标比例绘制。`36 × 36` 的 Retina 资源不能只在左下角画一个 `18 × 18` 图形，否则系统缩回 18 pt 后，图形只剩正常大小的一半。构建脚本会检查两档资源的可见边界和像素覆盖比例，并使用标准方形菜单栏槽位展示图标。

## 文件

- `brand/pasteory-app-icon.png`：应用图标预览。
- `brand/pasteory-app-icon-64.png`、`brand/pasteory-app-icon-32.png`：小尺寸检查图。
- `brand/pasteory-menu-bar-preview.png`：菜单栏浅色、深色模式预览。
- `brand/pasteory-menu-bar-icon.png`、`brand/pasteory-menu-bar-icon@2x.png`：菜单栏透明资源检查图。
- `brand/pasteory-icon-concept.png`：图像生成阶段的方向稿。
- `../scripts/generate_icon.swift`：构建时优先读取品牌准稿，并生成应用图标资源。

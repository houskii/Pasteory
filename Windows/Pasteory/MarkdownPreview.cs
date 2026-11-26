using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using Markdig;
using Markdig.Extensions.EmphasisExtras;
using Markdig.Extensions.TaskLists;
using Markdig.Syntax;
using MdInline = Markdig.Syntax.Inlines;
using MdTable = Markdig.Extensions.Tables;

namespace Pasteory.Windows;

internal static class MarkdownPreview
{
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .UsePipeTables(new MdTable.PipeTableOptions { UseGfmRules = true })
        .UseTaskLists().UseEmphasisExtras(EmphasisExtraOptions.Strikethrough).DisableHtml().Build();
    private static readonly List<(Guid Id, string Source, Task<MarkdownDocument> Parse)> Recent = [];
    private static readonly FontFamily Monospace = new("Consolas");

    internal static Task<MarkdownDocument> ParseAsync(Guid id, string source)
    {
        lock (Recent)
        {
            int index = Recent.FindIndex(entry => entry.Id == id && entry.Source == source);
            var entry = index >= 0 ? Recent[index] : (id, source, Task.Run(() => Markdown.Parse(source, Pipeline)));
            if (index >= 0) Recent.RemoveAt(index);
            Recent.Add(entry);
            if (Recent.Count > 8) Recent.RemoveAt(0);
            return entry.Item3;
        }
    }

    internal static bool LooksFormatted(MarkdownDocument document) =>
        document.Any(block => block is HeadingBlock or ListBlock or QuoteBlock or CodeBlock or MdTable.Table or ThematicBreakBlock) ||
        document.Descendants<MdInline.Inline>().Any(inline => inline is MdInline.EmphasisInline or MdInline.CodeInline or MdInline.LinkInline);

    internal static FlowDocument Render(MarkdownDocument markdown, Action<Uri> openLink)
    {
        var document = new FlowDocument { PagePadding = new Thickness(6), FontSize = 14 };
        document.SetResourceReference(FlowDocument.ForegroundProperty, "Ink");
        AddBlocks(document.Blocks, markdown, openLink);
        return document;
    }

    private static void AddBlocks(BlockCollection blocks, ContainerBlock content, Action<Uri> openLink)
    {
        foreach (var item in content)
        {
            switch (item)
            {
                case HeadingBlock heading:
                    var title = RenderParagraph(heading.Inline, openLink);
                    title.FontSize = Math.Max(15, 25 - heading.Level * 2);
                    title.FontWeight = FontWeights.SemiBold;
                    title.Margin = new Thickness(0, 9, 0, 5);
                    blocks.Add(title);
                    break;
                case ParagraphBlock paragraph:
                    blocks.Add(RenderParagraph(paragraph.Inline, openLink));
                    break;
                case CodeBlock code:
                    var sample = new Paragraph(new Run(code.Lines.ToString()))
                    {
                        FontFamily = Monospace, FontSize = 13, Padding = new Thickness(8), Margin = new Thickness(0, 5, 0, 7)
                    };
                    sample.SetResourceReference(TextElement.BackgroundProperty, "CodeBackground");
                    blocks.Add(sample);
                    break;
                case ListBlock entries:
                    blocks.Add(RenderList(entries, openLink));
                    break;
                case QuoteBlock quote:
                    var section = new Section { Padding = new Thickness(10, 0, 0, 0), BorderThickness = new Thickness(3, 0, 0, 0) };
                    section.SetResourceReference(Section.BorderBrushProperty, "Line");
                    section.SetResourceReference(TextElement.ForegroundProperty, "Muted");
                    AddBlocks(section.Blocks, quote, openLink);
                    blocks.Add(section);
                    break;
                case MdTable.Table table:
                    blocks.Add(RenderTable(table, openLink));
                    break;
                case ThematicBreakBlock:
                    var rule = new Paragraph { BorderThickness = new Thickness(0, 0, 0, 1), Margin = new Thickness(0, 3, 0, 8) };
                    rule.SetResourceReference(Paragraph.BorderBrushProperty, "Line");
                    blocks.Add(rule);
                    break;
            }
        }
    }

    private static Paragraph RenderParagraph(MdInline.ContainerInline? content, Action<Uri> openLink)
    {
        var paragraph = new Paragraph { Margin = new Thickness(0, 1, 0, 5) };
        AddInlines(paragraph.Inlines, content, openLink);
        return paragraph;
    }

    private static System.Windows.Documents.List RenderList(ListBlock entries, Action<Uri> openLink)
    {
        var items = entries.OfType<ListItemBlock>().ToArray();
        bool tasksOnly = items.Length > 0 && items.All(item => item.FirstOrDefault() is ParagraphBlock { Inline: { } text } &&
            text.Descendants<TaskList>().Any());
        var list = new System.Windows.Documents.List
        {
            Padding = new Thickness(tasksOnly ? 14 : 23, 0, 0, 0), Margin = new Thickness(0, 1, 0, 5),
            MarkerStyle = entries.IsOrdered ? TextMarkerStyle.Decimal : tasksOnly ? TextMarkerStyle.None : TextMarkerStyle.Disc
        };
        if (entries.IsOrdered && int.TryParse(entries.OrderedStart, NumberStyles.None, CultureInfo.InvariantCulture, out int start) && start > 0)
            list.StartIndex = start;
        foreach (var item in items)
        {
            var entry = new ListItem();
            AddBlocks(entry.Blocks, item, openLink);
            list.ListItems.Add(entry);
        }
        return list;
    }

    private static Table RenderTable(MdTable.Table source, Action<Uri> openLink)
    {
        var table = new Table { CellSpacing = 0, Margin = new Thickness(0, 5, 0, 7) };
        var rows = new TableRowGroup();
        table.RowGroups.Add(rows);
        foreach (var line in source.OfType<MdTable.TableRow>())
        {
            var row = new TableRow();
            if (line.IsHeader)
            {
                row.FontWeight = FontWeights.SemiBold;
                row.SetResourceReference(TextElement.BackgroundProperty, "SoftSurface");
            }
            foreach (var item in line.OfType<MdTable.TableCell>())
            {
                var cell = new TableCell { Padding = new Thickness(6, 4, 6, 4), BorderThickness = new Thickness(.5) };
                cell.SetResourceReference(TableCell.BorderBrushProperty, "Line");
                AddBlocks(cell.Blocks, item, openLink);
                row.Cells.Add(cell);
            }
            rows.Rows.Add(row);
        }
        return table;
    }

    private static void AddInlines(InlineCollection target, MdInline.ContainerInline? content, Action<Uri> openLink)
    {
        if (content is null) return;
        foreach (var inline in content)
        {
            switch (inline)
            {
                case MdInline.LiteralInline literal:
                    target.Add(new Run(literal.Content.ToString()));
                    break;
                case MdInline.HtmlEntityInline entity:
                    target.Add(new Run(entity.Transcoded.ToString()));
                    break;
                case MdInline.LineBreakInline { IsHard: true }:
                    target.Add(new LineBreak());
                    break;
                case MdInline.LineBreakInline:
                    target.Add(new Run(" "));
                    break;
                case MdInline.CodeInline code:
                    var sample = new Run(code.Content) { FontFamily = Monospace };
                    sample.SetResourceReference(TextElement.BackgroundProperty, "CodeBackground");
                    target.Add(sample);
                    break;
                case MdInline.EmphasisInline emphasis:
                    Span styled = emphasis.DelimiterChar == '~' ? new Span { TextDecorations = TextDecorations.Strikethrough } :
                        emphasis.DelimiterCount >= 2 ? new Bold() : new Italic();
                    AddInlines(styled.Inlines, emphasis, openLink);
                    target.Add(styled);
                    break;
                case MdInline.LinkInline { IsImage: true } image:
                    var description = new Span(new Run($"[{Labels.Get("Image")}] "));
                    description.SetResourceReference(TextElement.ForegroundProperty, "Muted");
                    AddInlines(description.Inlines, image, openLink);
                    target.Add(description);
                    break;
                case MdInline.LinkInline link:
                    var clickable = Link(link.Url, openLink);
                    AddInlines(clickable.Inlines, link, openLink);
                    target.Add(clickable);
                    break;
                case MdInline.AutolinkInline autoLink:
                    var address = Link(autoLink.IsEmail ? null : autoLink.Url, openLink);
                    address.Inlines.Add(new Run(autoLink.Url));
                    target.Add(address);
                    break;
                case TaskList task:
                    target.Add(new Run(task.Checked ? "☑ " : "☐ "));
                    break;
                case MdInline.ContainerInline nested:
                    AddInlines(target, nested, openLink);
                    break;
            }
        }
    }

    private static Span Link(string? target, Action<Uri> openLink)
    {
        if (!Uri.TryCreate(target, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") ||
            uri.Host.Length == 0 || uri.UserInfo.Length > 0) return new Span();
        var link = new Hyperlink { NavigateUri = uri };
        link.SetResourceReference(TextElement.ForegroundProperty, "LinkInk");
        link.RequestNavigate += (_, args) => { args.Handled = true; openLink(uri); };
        return link;
    }
}

/**
 * 排版：文本 / 表格 / 照片 → 页面内容模型（PageContent）。
 *
 * 这里只做「算位置」，不碰像素；像素由 PageRenderer 按渲染带绘制。
 * 好处是页数、分页位置在发送前就确定了，且不受整页内存限制。
 */

import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Constants } from '../common/Constants';
import { ImageBox, LineSeg, PageContent, TextLine } from './PageContent';
import { TextFont } from './TextFont';
import { XlsxSheet } from './OfficeParser';

export class DocumentRasterizer {
  /** 制表符按 4 个空格展开 */
  private static readonly TAB_AS: string = '    ';

  /** 去掉字符串尾部空格 */
  private static trimEnd(s: string): string {
    let end = s.length;
    while (end > 0 && s.charAt(end - 1) === ' ') {
      end--;
    }
    return s.substring(0, end);
  }

  /**
   * 按可用宽度折行。
   * 中文逐字折行；英文优先在空格处断开，单词过长时才硬断。
   */
  static wrapText(text: string, font: TextFont, maxWidth: number): string[] {
    const lines: string[] = [];
    const normalized = text.split('\r\n').join('\n').split('\r').join('\n')
      .split('\t').join(DocumentRasterizer.TAB_AS);
    const paragraphs = normalized.split('\n');
    for (let p = 0; p < paragraphs.length; p++) {
      DocumentRasterizer.wrapParagraph(paragraphs[p], font, maxWidth, lines);
    }
    return lines;
  }

  private static wrapParagraph(para: string, font: TextFont, maxWidth: number, out: string[]): void {
    if (para.length === 0) {
      out.push('');
      return;
    }
    let lineStart = 0;
    let width = 0;
    let lastSpaceEnd = -1; // 最近一个空格之后的下标，作为优先断行点
    let i = 0;
    while (i < para.length) {
      const len = TextFont.charLengthAt(para, i);
      const ch = para.substring(i, i + len);
      const w = font.charWidth(ch);
      if (width + w > maxWidth && i > lineStart) {
        let breakAt = i;
        if (lastSpaceEnd > lineStart && lastSpaceEnd < i) {
          breakAt = lastSpaceEnd;
        }
        out.push(DocumentRasterizer.trimEnd(para.substring(lineStart, breakAt)));
        lineStart = breakAt;
        // 跳过折行处的连续空格，避免下一行以空格开头
        while (lineStart < para.length && para.charAt(lineStart) === ' ') {
          lineStart++;
        }
        i = lineStart;
        width = 0;
        lastSpaceEnd = -1;
        continue;
      }
      width += w;
      i += len;
      if (ch === ' ') {
        lastSpaceEnd = i;
      }
    }
    if (lineStart < para.length) {
      out.push(DocumentRasterizer.trimEnd(para.substring(lineStart)));
    }
  }

  /**
   * 纯文本排版成多页。
   *
   * @param text 文本内容
   * @param font 字型
   * @param pageWidth 页面（可打印区）宽
   * @param pageHeight 页面（可打印区）高
   * @param margin 页内留白（像素）
   */
  static layoutText(text: string, font: TextFont,
    pageWidth: number, pageHeight: number, margin: number): PageContent[] {
    const pages: PageContent[] = [];
    const usableWidth = Math.max(1, pageWidth - margin * 2);
    const lineHeight = font.lineHeight;
    const bottomLimit = pageHeight - margin;
    const lines = DocumentRasterizer.wrapText(text, font, usableWidth);

    let page = new PageContent();
    let hasContent = false;
    let y = margin;
    for (let i = 0; i < lines.length; i++) {
      if (y + lineHeight > bottomLimit) {
        if (hasContent) {
          pages.push(page);
        }
        page = new PageContent();
        hasContent = false;
        y = margin;
      }
      const line = lines[i];
      if (line.length > 0) {
        page.texts.push(new TextLine(margin, y + font.ascent, line));
        hasContent = true;
      }
      y += lineHeight;
    }
    if (hasContent) {
      pages.push(page);
    }
    return pages;
  }

  /**
   * xlsx 表格排版成多页（带网格线，单元格内自动折行）。
   */
  static layoutGrid(sheet: XlsxSheet, font: TextFont,
    pageWidth: number, pageHeight: number, margin: number): PageContent[] {
    const pages: PageContent[] = [];
    const usableWidth = Math.max(1, pageWidth - margin * 2);
    const usableHeight = Math.max(1, pageHeight - margin * 2);
    const cols = Math.max(1, sheet.maxCols);
    const colWidth = Math.max(Math.round(font.sizePx), Math.floor(usableWidth / cols));
    const pad = Math.max(2, Math.round(font.sizePx * 0.28));
    const lineHeight = font.lineHeight;
    const tableWidth = colWidth * cols;

    // 预先折行并算出每行高度
    const wrapped: string[][][] = [];
    const rowHeights: number[] = [];
    for (let r = 0; r < sheet.maxRows; r++) {
      const row = sheet.rows[r];
      const cells: string[][] = [];
      let maxLines = 1;
      for (let c = 0; c < cols; c++) {
        const value = (row !== undefined && c < row.length) ? row[c] : '';
        const cellLines = value.length === 0
          ? ['']
          : DocumentRasterizer.wrapText(value, font, colWidth - pad * 2);
        cells.push(cellLines);
        if (cellLines.length > maxLines) {
          maxLines = cellLines.length;
        }
      }
      wrapped.push(cells);
      const h = maxLines * lineHeight + pad * 2;
      rowHeights.push(Math.min(h, usableHeight));
    }

    let page = new PageContent();
    let y = margin;
    let rowsOnPage = 0;
    for (let r = 0; r < sheet.maxRows; r++) {
      const rowHeight = rowHeights[r];
      if (y + rowHeight > pageHeight - margin && rowsOnPage > 0) {
        // 收尾：补最后一条横线后换页
        page.strokes.push(new LineSeg(margin, y, margin + tableWidth, y));
        pages.push(page);
        page = new PageContent();
        y = margin;
        rowsOnPage = 0;
      }
      // 行顶横线 + 各列竖线
      page.strokes.push(new LineSeg(margin, y, margin + tableWidth, y));
      for (let c = 0; c <= cols; c++) {
        const x = margin + c * colWidth;
        page.strokes.push(new LineSeg(x, y, x, y + rowHeight));
      }
      // 单元格文字
      for (let c = 0; c < cols; c++) {
        const cellLines = wrapped[r][c];
        const x = margin + c * colWidth + pad;
        for (let li = 0; li < cellLines.length; li++) {
          const baseline = y + pad + li * lineHeight + font.ascent;
          if (baseline + font.descent > y + rowHeight) {
            break; // 超出该行高度的内容截断
          }
          if (cellLines[li].length > 0) {
            page.texts.push(new TextLine(x, baseline, cellLines[li]));
          }
        }
      }
      y += rowHeight;
      rowsOnPage++;
    }
    if (rowsOnPage > 0) {
      page.strokes.push(new LineSeg(margin, y, margin + tableWidth, y));
      pages.push(page);
    }
    return pages;
  }

  /**
   * 照片排版：解码 → 等比缩放 → 居中。
   *
   * 若把照片旋转 90° 能明显放大打印面积（例如横幅照片打在纵向纸上），
   * 则自动旋转，避免中间一小条、上下大片空白。
   *
   * @param uri 相册/文件 URI
   * @param pageWidth 页面（可打印区）宽
   * @param pageHeight 页面（可打印区）高
   */
  static async layoutPhoto(uri: string, pageWidth: number, pageHeight: number): Promise<PageContent> {
    const content = new PageContent();
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(file.fd);
      const info = await source.getImageInfo();
      const srcWidth = info.size.width;
      const srcHeight = info.size.height;
      if (srcWidth <= 0 || srcHeight <= 0) {
        throw new Error('图片尺寸异常，无法打印');
      }

      const direct = Math.min(pageWidth / srcWidth, pageHeight / srcHeight);
      const rotated = Math.min(pageWidth / srcHeight, pageHeight / srcWidth);
      const needRotate = rotated > direct * 1.15;

      // 解码尺寸：不超过打印所需尺寸（放大无意义），并受总像素预算限制
      const fitScale = needRotate ? rotated : direct;
      let decodeWidth = Math.max(1, Math.round(srcWidth * Math.min(1, fitScale)));
      let decodeHeight = Math.max(1, Math.round(srcHeight * Math.min(1, fitScale)));
      const pixels = decodeWidth * decodeHeight;
      if (pixels > Constants.MAX_PIXELS) {
        const shrink = Math.sqrt(Constants.MAX_PIXELS / pixels);
        decodeWidth = Math.max(1, Math.round(decodeWidth * shrink));
        decodeHeight = Math.max(1, Math.round(decodeHeight * shrink));
      }

      const pixelMap = await source.createPixelMap({
        desiredSize: { width: decodeWidth, height: decodeHeight },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      if (needRotate) {
        pixelMap.rotateSync(90);
      }

      const drawWidth = needRotate ? decodeHeight : decodeWidth;
      const drawHeight = needRotate ? decodeWidth : decodeHeight;
      const scale = Math.min(pageWidth / drawWidth, pageHeight / drawHeight);
      const targetWidth = Math.max(1, Math.floor(drawWidth * scale));
      const targetHeight = Math.max(1, Math.floor(drawHeight * scale));
      const left = Math.floor((pageWidth - targetWidth) / 2);
      const top = Math.floor((pageHeight - targetHeight) / 2);
      content.imageBox = new ImageBox(pixelMap, left, top, targetWidth, targetHeight);
      return content;
    } finally {
      if (source !== null) {
        source.release();
      }
      fs.closeSync(file);
    }
  }
}

/**
 * .docx → PDF：按 Word 的段落/表格/图片信息排版，写出一份真正的 PDF。
 *
 * 坐标约定（排版阶段）：原点在页面左上角，y 向下，单位点（pt）。
 * 写出 PDF 时再翻成 PDF 用户空间（原点左下、y 向上）。
 *
 * 字体策略：
 *  - 能用 WinAnsi 表示的字符走标准 14 字体（Helvetica / Times / Courier），宽度用 AFM 官方度量；
 *  - 其余字符（中文为主）走 STSong-Light + UniGB-UCS2-H，宽度按全角 1em、半角 0.5em 估算。
 * 排版宽度和写入 PDF 时声明的宽度用同一套函数，所以打印出来不会挤在一起。
 */

import { PngDecoder } from '../common/PngDecoder';
import { BmpDecoder } from '../common/BmpDecoder';
import { PdfStdFonts } from '../pdf/PdfStdFonts';
import {
  PdfBuilder,
  PdfBuiltinFont,
  PdfImagePayload,
  PdfOutPage
} from '../pdf/PdfBuilder';
import {
  DocxAlign,
  DocxBlock,
  DocxBlockKind,
  DocxCell,
  DocxDocument,
  DocxImage,
  DocxParagraph,
  DocxRun,
  DocxRunStyle,
  DocxSection,
  DocxTable
} from './DocxModel';

/** 排版阶段的一个原子：一段相同字体的文字，或一张图片，或强制换行/换页 */
class Atom {
  /** 0 = 文字，1 = 图片，2 = 硬换行，3 = 换页 */
  kind: number = 0;
  text: string = '';
  widthPt: number = 0;
  sizePt: number = 10.5;
  fontKind: number = PdfBuiltinFont.SANS;
  bold: boolean = false;
  italic: boolean = false;
  color: number = 0;
  cjk: boolean = false;
  image: PdfImagePayload | null = null;
  imageWidthPt: number = 0;
  imageHeightPt: number = 0;
}

/** 一行上的一个绘制项（已定位） */
class LineSpan {
  x: number = 0;
  /** 基线 y（距页面顶） */
  y: number = 0;
  atom: Atom = new Atom();
}

/** 已定位的矩形（表格底纹 / 边框） */
class LaidRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
  fill: number = -1;
  stroke: number = -1;
  strokeWidth: number = 0.5;
}

/** 已定位的图片 */
class LaidImage {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
  payload: PdfImagePayload = new PdfImagePayload();
}

/** 一页攒下来的内容 */
class PageBuf {
  spans: LineSpan[] = [];
  rects: LaidRect[] = [];
  images: LaidImage[] = [];
}

export class DocxToPdf {
  private readonly section: DocxSection;
  private readonly builder: PdfBuilder = new PdfBuilder();
  private readonly pages: PageBuf[] = [];
  private page: PageBuf = new PageBuf();
  /** 当前写入 y（距页面顶，内容区之内） */
  private y: number = 0;
  private imageSeq: number = 0;
  /** 同一张 Word 图片只编码一次（测量高度时也会走到图片路径） */
  private readonly imageCache: Map<DocxImage, PdfImagePayload | null> =
    new Map<DocxImage, PdfImagePayload | null>();
  /** 表格单元格内部禁止换页，避免一行被拆到两页 */
  private freezePaging: boolean = false;

  private constructor(section: DocxSection) {
    this.section = section;
    this.y = section.marginTopPt;
    this.pages.push(this.page);
  }

  /** 把解析好的 Word 文档转成 PDF 字节 */
  static convert(doc: DocxDocument): Uint8Array {
    const conv = new DocxToPdf(doc.section);
    conv.layoutBlocks(doc.blocks, conv.contentLeft(), conv.contentWidth(), 0);
    return conv.build();
  }

  private contentLeft(): number {
    return this.section.marginLeftPt;
  }

  private contentWidth(): number {
    return this.section.contentWidthPt;
  }

  private contentBottom(): number {
    return this.section.heightPt - this.section.marginBottomPt;
  }

  /** 排一组块（文档正文或单元格内部），x0/width 是可用区域 */
  private layoutBlocks(blocks: DocxBlock[], x0: number, width: number, depth: number): void {
    if (depth > 6) {
      return;
    }
    for (let i = 0; i < blocks.length; i++) {
      const block = blocks[i];
      if (block.kind === DocxBlockKind.PARAGRAPH) {
        this.layoutParagraph(block as DocxParagraph, x0, width);
      } else {
        this.layoutTable(block as DocxTable, x0, width, depth);
      }
    }
  }

  /** 换页：保留当前 y 对应的页眉位置 */
  private newPage(): void {
    this.page = new PageBuf();
    this.pages.push(this.page);
    this.y = this.section.marginTopPt;
  }

  /** 确保还能放下 height 点，否则换页 */
  private ensureSpace(height: number): void {
    if (this.freezePaging) {
      return;
    }
    if (this.y + height > this.contentBottom() && this.y > this.section.marginTopPt + 0.5) {
      this.newPage();
    }
  }

  /** 排一个段落 */
  private layoutParagraph(para: DocxParagraph, x0: number, width: number): void {
    const style = para.style;
    const left = Math.max(0, style.indentLeftPt);
    const right = Math.max(0, style.indentRightPt);
    const firstExtra = style.indentFirstPt;
    const bodyWidth = Math.max(12, width - left - right);
    const firstWidth = Math.max(12, bodyWidth - firstExtra);

    if (para.runs.length === 1 && para.runs[0].breakKind === DocxRun.BREAK_PAGE) {
      this.newPage();
      return;
    }

    const atoms = this.paragraphToAtoms(para, bodyWidth);
    if (atoms.length === 0 && para.bullet.length === 0) {
      // 空段落：占一行
      const h = 10.5 * Math.max(0.8, style.lineMultiple);
      this.y += style.spaceBeforePt;
      this.ensureSpace(h);
      this.y += h + style.spaceAfterPt;
      return;
    }

    this.y += style.spaceBeforePt;
    let line: Atom[] = [];
    let lineWidth = 0;
    let lineMaxSize = 10.5;
    let isFirst = true;
    let avail = firstWidth;
    const bullet = para.bullet;
    let bulletAtom: Atom | null = null;
    if (bullet.length > 0) {
      bulletAtom = this.makeTextAtom(bullet + '  ', para.bulletStyle);
    }

    const flush = (): void => {
      if (line.length === 0 && bulletAtom === null) {
        return;
      }
      const maxSize = lineMaxSize;
      const lineHeight = style.lineExactPt > 0
        ? style.lineExactPt
        : maxSize * Math.max(0.9, style.lineMultiple) * 1.25;
      this.ensureSpace(lineHeight);
      const indent = isFirst ? left + firstExtra : left;
      let startX = x0 + indent;
      const used = lineWidth + (isFirst && bulletAtom !== null ? bulletAtom.widthPt : 0);
      const extra = avail - used;
      if (style.align === DocxAlign.CENTER) {
        startX += extra / 2;
      } else if (style.align === DocxAlign.RIGHT) {
        startX += extra;
      }
      const baseline = this.y + maxSize * 0.8;
      let x = startX;
      if (isFirst && bulletAtom !== null) {
        const span = new LineSpan();
        span.x = x;
        span.y = baseline;
        span.atom = bulletAtom;
        this.page.spans.push(span);
        x += bulletAtom.widthPt;
      }
      const merged = DocxToPdf.mergeAtoms(line);
      // 两端对齐：把多余空间分给空格
      const gaps = style.align === DocxAlign.JUSTIFY && extra > 0.5 && !isFirst
        ? DocxToPdf.spaceCount(merged) : 0;
      const gapExtra = gaps > 0 ? extra / gaps : 0;
      for (let i = 0; i < merged.length; i++) {
        const atom = merged[i];
        if (atom.kind === 1 && atom.image !== null) {
          const img = new LaidImage();
          img.x = x;
          img.y = this.y;
          img.w = atom.imageWidthPt;
          img.h = atom.imageHeightPt;
          img.payload = atom.image;
          this.page.images.push(img);
          x += atom.imageWidthPt;
          continue;
        }
        const span = new LineSpan();
        span.x = x;
        span.y = baseline;
        span.atom = atom;
        this.page.spans.push(span);
        x += atom.widthPt;
        if (gapExtra > 0 && atom.text === ' ') {
          x += gapExtra;
        }
      }
      this.y += lineHeight;
      line = [];
      lineWidth = 0;
      lineMaxSize = 10.5;
      isFirst = false;
      avail = bodyWidth;
      bulletAtom = null;
    };

    for (let i = 0; i < atoms.length; i++) {
      const atom = atoms[i];
      if (atom.kind === 3) {
        flush();
        this.newPage();
        isFirst = true;
        avail = firstWidth;
        continue;
      }
      if (atom.kind === 2) {
        flush();
        continue;
      }
      if (lineWidth + atom.widthPt > avail && line.length > 0) {
        flush();
      }
      // 单个原子比行宽还长：硬放进去（下一轮 flush 再处理）
      if (atom.widthPt > avail && line.length === 0 && atom.kind === 1) {
        const scale = avail / atom.widthPt;
        atom.imageWidthPt *= scale;
        atom.imageHeightPt *= scale;
        atom.widthPt = atom.imageWidthPt;
      }
      line.push(atom);
      lineWidth += atom.widthPt;
      if (atom.sizePt > lineMaxSize) {
        lineMaxSize = atom.sizePt;
      }
      if (atom.imageHeightPt > lineMaxSize) {
        lineMaxSize = atom.imageHeightPt;
      }
    }
    flush();
    this.y += style.spaceAfterPt;
  }

  /** 统计一行里的空格原子个数（两端对齐用） */
  private static spaceCount(line: Atom[]): number {
    let n = 0;
    for (let i = 0; i < line.length; i++) {
      if (line[i].text === ' ') {
        n++;
      }
    }
    return n;
  }

  /** 合并相邻的同字体文字原子，减少 PDF 里碎片化的 Tj */
  private static mergeAtoms(line: Atom[]): Atom[] {
    const out: Atom[] = [];
    for (let i = 0; i < line.length; i++) {
      const atom = line[i];
      if (out.length === 0 || atom.kind !== 0 || atom.text === ' ') {
        out.push(atom);
        continue;
      }
      const prev = out[out.length - 1];
      if (prev.kind === 0 && prev.text !== ' ' && prev.fontKind === atom.fontKind &&
        prev.bold === atom.bold && prev.italic === atom.italic &&
        prev.color === atom.color && prev.sizePt === atom.sizePt && prev.cjk === atom.cjk) {
        prev.text += atom.text;
        prev.widthPt += atom.widthPt;
      } else {
        out.push(atom);
      }
    }
    return out;
  }

  /** 段落 → 原子序列（按字体切换切开，并处理折行点） */
  private paragraphToAtoms(para: DocxParagraph, maxImageWidth: number): Atom[] {
    const out: Atom[] = [];
    for (let r = 0; r < para.runs.length; r++) {
      const run = para.runs[r];
      if (run.breakKind === DocxRun.BREAK_PAGE) {
        const a = new Atom();
        a.kind = 3;
        out.push(a);
        continue;
      }
      if (run.breakKind === DocxRun.BREAK_LINE) {
        const a = new Atom();
        a.kind = 2;
        out.push(a);
        continue;
      }
      if (run.image !== null) {
        const img = this.makeImageAtom(run.image, maxImageWidth);
        if (img !== null) {
          out.push(img);
        }
        continue;
      }
      this.splitTextRun(run, out);
    }
    return out;
  }

  /** 把一段文字拆成「同一字体 + 可断行」的原子 */
  private splitTextRun(run: DocxRun, out: Atom[]): void {
    const text = run.text;
    let i = 0;
    while (i < text.length) {
      const c = text.charAt(i);
      if (c === '\t') {
        out.push(this.makeTextAtom('    ', run.style));
        i++;
        continue;
      }
      if (c === '\n' || c === '\r') {
        const a = new Atom();
        a.kind = 2;
        out.push(a);
        i++;
        continue;
      }
      // 连续空格各成一个原子，便于两端对齐
      if (c === ' ') {
        out.push(this.makeTextAtom(' ', run.style));
        i++;
        continue;
      }
      // 把相同字体的连续字符收成一段；CJK 每个字单独成原子，方便按字折行
      const code = text.charCodeAt(i);
      const len = (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) ? 2 : 1;
      const ch = text.substring(i, i + len);
      const cjk = !PdfBuilder.isWinAnsiChar(len === 1 ? code : 0x10000);
      if (cjk) {
        out.push(this.makeTextAtom(ch, run.style));
        i += len;
        continue;
      }
      // 西文：读到空格/制表/CJK 为止，作为单词
      let j = i + len;
      while (j < text.length) {
        const cc = text.charCodeAt(j);
        if (cc === 0x20 || cc === 0x09 || cc === 0x0a || cc === 0x0d) {
          break;
        }
        if (!PdfBuilder.isWinAnsiChar(cc)) {
          break;
        }
        j++;
      }
      out.push(this.makeTextAtom(text.substring(i, j), run.style));
      i = j;
    }
  }

  /** 按字符格式构造文字原子，并累计宽度 */
  private makeTextAtom(text: string, style: DocxRunStyle): Atom {
    const atom = new Atom();
    atom.kind = 0;
    atom.text = text;
    atom.sizePt = style.vertAlign !== 0 ? style.sizePt * 0.65 : Math.max(4, style.sizePt);
    atom.bold = style.bold;
    atom.italic = style.italic;
    atom.color = style.color;
    let latinKind = PdfBuiltinFont.SANS;
    if (style.mono) {
      latinKind = PdfBuiltinFont.MONO;
    } else if (style.serif) {
      latinKind = PdfBuiltinFont.SERIF;
    }
    let width = 0;
    let anyCjk = false;
    for (let i = 0; i < text.length; i++) {
      const code = text.charCodeAt(i);
      const cjk = !PdfBuilder.isWinAnsiChar(code);
      if (cjk) {
        anyCjk = true;
        const em = PdfStdFonts.estimateWidth(code);
        width += em / 1000 * atom.sizePt;
        this.builder.noteCjkCode(code, em);
      } else {
        width += PdfBuilder.latinWidth(latinKind, style.bold, style.italic, code) / 1000 * atom.sizePt;
      }
    }
    atom.cjk = anyCjk;
    atom.fontKind = anyCjk ? PdfBuiltinFont.CJK : latinKind;
    atom.widthPt = width;
    return atom;
  }

  /** 图片原子：JPEG 原样嵌入，PNG 解码成 RGB，其它格式跳过 */
  private makeImageAtom(image: DocxImage, maxWidth: number): Atom | null {
    let payload: PdfImagePayload | null | undefined = this.imageCache.get(image);
    if (payload === undefined) {
      payload = this.encodeImage(image);
      this.imageCache.set(image, payload);
      if (payload !== null) {
        payload.name = 'Im' + this.imageSeq;
        this.imageSeq++;
      }
    }
    if (payload === null) {
      return null;
    }
    const atom = new Atom();
    atom.kind = 1;
    atom.image = payload;
    let w = image.widthPt;
    let h = image.heightPt;
    if (w > maxWidth && w > 0) {
      const s = maxWidth / w;
      w *= s;
      h *= s;
    }
    atom.imageWidthPt = w;
    atom.imageHeightPt = h;
    atom.widthPt = w;
    atom.sizePt = h;
    return atom;
  }

  /** 把 Word 图片变成 PDF 图像载荷 */
  private encodeImage(image: DocxImage): PdfImagePayload | null {
    if (image.data.length < 8) {
      return null;
    }
    const payload = new PdfImagePayload();
    if (image.data[0] === 0xff && image.data[1] === 0xd8) {
      payload.isJpeg = true;
      payload.data = image.data;
      payload.widthPx = Math.max(1, Math.round(image.widthPt * 96 / 72));
      payload.heightPx = Math.max(1, Math.round(image.heightPt * 96 / 72));
      // JPEG 的像素尺寸以文件头为准更好，解析 SOF 标记
      const sof = DocxToPdf.jpegSize(image.data);
      if (sof !== null) {
        payload.widthPx = sof[0];
        payload.heightPx = sof[1];
      }
      return payload;
    }
    const png = PngDecoder.decode(image.data);
    if (png !== null) {
      payload.isJpeg = false;
      payload.widthPx = png.width;
      payload.heightPx = png.height;
      payload.data = png.rgb;
      return payload;
    }
    const bmp = BmpDecoder.decode(image.data);
    if (bmp === null) {
      return null;
    }
    payload.isJpeg = false;
    payload.widthPx = bmp.width;
    payload.heightPx = bmp.height;
    payload.data = bmp.rgb;
    return payload;
  }

  /** 从 JPEG 文件头读像素尺寸，失败返回 null */
  private static jpegSize(data: Uint8Array): number[] | null {
    let i = 2;
    while (i + 8 < data.length) {
      if (data[i] !== 0xff) {
        i++;
        continue;
      }
      const marker = data[i + 1];
      if (marker === 0xd8 || marker === 0xd9 || marker === 0x01) {
        i += 2;
        continue;
      }
      const len = (data[i + 2] << 8) | data[i + 3];
      // SOF0~SOF3 / SOF9~SOF11 带尺寸
      if ((marker >= 0xc0 && marker <= 0xc3) || (marker >= 0xc9 && marker <= 0xcb)) {
        if (i + 8 < data.length) {
          const h = (data[i + 5] << 8) | data[i + 6];
          const w = (data[i + 7] << 8) | data[i + 8];
          return [w, h];
        }
      }
      i += 2 + len;
    }
    return null;
  }

  /** 排表格 */
  private layoutTable(table: DocxTable, x0: number, width: number, depth: number): void {
    const cols = table.columnsPt.length === 0 ? [width] : table.columnsPt.slice();
    let sum = 0;
    let zeros = 0;
    for (let i = 0; i < cols.length; i++) {
      if (cols[i] <= 0) {
        zeros++;
      } else {
        sum += cols[i];
      }
    }
    if (zeros > 0) {
      const rest = Math.max(12, width - sum) / zeros;
      for (let i = 0; i < cols.length; i++) {
        if (cols[i] <= 0) {
          cols[i] = rest;
        }
      }
      sum = width;
    }
    if (sum > width && sum > 0) {
      const s = width / sum;
      for (let i = 0; i < cols.length; i++) {
        cols[i] *= s;
      }
    }
    const pad = table.cellPadPt;

    for (let r = 0; r < table.rows.length; r++) {
      const row = table.rows[r];
      // 先在「虚拟 y」上量出单元格内容高度（不真正画），再按最大高度画边框并填内容
      const cellHeights: number[] = [];
      const cellXs: number[] = [];
      const cellWs: number[] = [];
      let x = x0;
      let colIndex = 0;
      for (let c = 0; c < row.cells.length; c++) {
        const cell = row.cells[c];
        let w = 0;
        for (let k = 0; k < cell.gridSpan && colIndex < cols.length; k++) {
          w += cols[colIndex];
          colIndex++;
        }
        if (w <= 0) {
          w = width / Math.max(1, row.cells.length);
        }
        cellXs.push(x);
        cellWs.push(w);
        x += w;
        if (cell.vMergeContinue) {
          cellHeights.push(0);
          continue;
        }
        cellHeights.push(this.measureBlocks(cell.blocks, Math.max(8, w - pad * 2), depth + 1) + pad * 2);
      }
      let rowH = row.heightPt;
      for (let c = 0; c < cellHeights.length; c++) {
        if (cellHeights[c] > rowH) {
          rowH = cellHeights[c];
        }
      }
      if (rowH < 12) {
        rowH = 12;
      }
      this.ensureSpace(rowH);
      const rowTop = this.y;
      this.freezePaging = true;

      // 底纹 + 边框
      for (let c = 0; c < row.cells.length; c++) {
        const cell = row.cells[c];
        const rect = new LaidRect();
        rect.x = cellXs[c];
        rect.y = rowTop;
        rect.w = cellWs[c];
        rect.h = rowH;
        rect.fill = cell.fill;
        this.page.rects.push(rect);
        this.addCellBorders(cell, cellXs[c], rowTop, cellWs[c], rowH);
      }

      // 内容：每个单元格独立排，排完把 y 拨回行底
      for (let c = 0; c < row.cells.length; c++) {
        const cell = row.cells[c];
        if (cell.vMergeContinue) {
          continue;
        }
        this.y = rowTop + pad;
        this.layoutBlocks(cell.blocks, cellXs[c] + pad, Math.max(8, cellWs[c] - pad * 2), depth + 1);
      }
      this.y = rowTop + rowH;
      this.freezePaging = false;
    }
  }

  /** 单元格四边边框（每条边单独一条细矩形，避免 path 闭合问题） */
  private addCellBorders(cell: DocxCell, x: number, y: number, w: number, h: number): void {
    const b = cell.borders;
    const color = b.color;
    if (b.topPt > 0) {
      this.addStroke(x, y, w, b.topPt, color);
    }
    if (b.bottomPt > 0) {
      this.addStroke(x, y + h - b.bottomPt, w, b.bottomPt, color);
    }
    if (b.leftPt > 0) {
      this.addStroke(x, y, b.leftPt, h, color);
    }
    if (b.rightPt > 0) {
      this.addStroke(x + w - b.rightPt, y, b.rightPt, h, color);
    }
  }

  private addStroke(x: number, y: number, w: number, h: number, color: number): void {
    const rect = new LaidRect();
    rect.x = x;
    rect.y = y;
    rect.w = w;
    rect.h = h;
    rect.fill = color;
    this.page.rects.push(rect);
  }

  /**
   * 测量一组块的高度（不写入当前页）。
   * 用一个临时转换器在隔离的 y 上排一遍，只取高度差。
   * 为避免真的污染 pages，这里用简化估算：段落按折行后的行数 × 行高。
   */
  private measureBlocks(blocks: DocxBlock[], width: number, depth: number): number {
    if (depth > 6) {
      return 12;
    }
    let h = 0;
    for (let i = 0; i < blocks.length; i++) {
      const block = blocks[i];
      if (block.kind === DocxBlockKind.PARAGRAPH) {
        h += this.measureParagraph(block as DocxParagraph, width);
      } else {
        const table = block as DocxTable;
        // 粗估：每行至少 16pt，加上单元格内容
        for (let r = 0; r < table.rows.length; r++) {
          let rowH = table.rows[r].heightPt;
          const cols = Math.max(1, table.columnsPt.length);
          const cellW = width / cols;
          for (let c = 0; c < table.rows[r].cells.length; c++) {
            const ch = this.measureBlocks(table.rows[r].cells[c].blocks,
              Math.max(8, cellW - table.cellPadPt * 2), depth + 1) + table.cellPadPt * 2;
            if (ch > rowH) {
              rowH = ch;
            }
          }
          h += Math.max(12, rowH);
        }
      }
    }
    return h;
  }

  private measureParagraph(para: DocxParagraph, width: number): number {
    const style = para.style;
    const bodyWidth = Math.max(12, width - Math.max(0, style.indentLeftPt) - Math.max(0, style.indentRightPt));
    const atoms = this.paragraphToAtoms(para, bodyWidth);
    if (atoms.length === 0) {
      return style.spaceBeforePt + style.spaceAfterPt + 10.5 * Math.max(0.8, style.lineMultiple);
    }
    let lines = 1;
    let used = 0;
    let maxSize = 10.5;
    let total = style.spaceBeforePt + style.spaceAfterPt;
    const flushSize = (): void => {
      const lh = style.lineExactPt > 0 ? style.lineExactPt : maxSize * Math.max(0.9, style.lineMultiple) * 1.25;
      total += lh;
      maxSize = 10.5;
    };
    for (let i = 0; i < atoms.length; i++) {
      if (atoms[i].kind === 2 || atoms[i].kind === 3) {
        flushSize();
        lines++;
        used = 0;
        continue;
      }
      if (used + atoms[i].widthPt > bodyWidth && used > 0) {
        flushSize();
        lines++;
        used = 0;
      }
      used += atoms[i].widthPt;
      if (atoms[i].sizePt > maxSize) {
        maxSize = atoms[i].sizePt;
      }
      if (atoms[i].imageHeightPt > maxSize) {
        maxSize = atoms[i].imageHeightPt;
      }
    }
    flushSize();
    return total;
  }

  /** 把各页缓冲写成 PDF */
  private build(): Uint8Array {
    const outPages: PdfOutPage[] = [];
    for (let i = 0; i < this.pages.length; i++) {
      outPages.push(this.emitPage(this.pages[i]));
    }
    if (outPages.length === 0) {
      const empty = new PdfOutPage();
      empty.widthPt = this.section.widthPt;
      empty.heightPt = this.section.heightPt;
      outPages.push(empty);
    }
    return this.builder.build(outPages);
  }

  /** 一页缓冲 → PDF 页 */
  private emitPage(buf: PageBuf): PdfOutPage {
    const page = new PdfOutPage();
    page.widthPt = this.section.widthPt;
    page.heightPt = this.section.heightPt;
    const h = this.section.heightPt;
    const fonts = new Map<string, boolean>();
    const images: PdfImagePayload[] = [];
    const seenImg = new Map<string, boolean>();
    let content = '';

    // 先画矩形（底纹/边框），再画图，最后画文字——和 Word 的叠放接近
    for (let i = 0; i < buf.rects.length; i++) {
      const r = buf.rects[i];
      if (r.w <= 0 || r.h <= 0) {
        continue;
      }
      if (r.fill >= 0) {
        content += DocxToPdf.rgbOp(r.fill, true) + PdfBuilder.num(r.x) + ' ' +
          PdfBuilder.num(h - r.y - r.h) + ' ' + PdfBuilder.num(r.w) + ' ' +
          PdfBuilder.num(r.h) + ' re f\n';
      }
    }
    for (let i = 0; i < buf.images.length; i++) {
      const img = buf.images[i];
      if (!seenImg.has(img.payload.name)) {
        images.push(img.payload);
        seenImg.set(img.payload.name, true);
      }
      // cm 把单位正方形映射到图片矩形（PDF y 向上，原点在左下）
      content += 'q ' + PdfBuilder.num(img.w) + ' 0 0 ' + PdfBuilder.num(img.h) + ' ' +
        PdfBuilder.num(img.x) + ' ' + PdfBuilder.num(h - img.y - img.h) + ' cm /' +
        img.payload.name + ' Do Q\n';
    }

    content += 'BT\n';
    let lastFont = '';
    let lastSize = -1;
    let lastColor = -1;
    for (let i = 0; i < buf.spans.length; i++) {
      const span = buf.spans[i];
      const atom = span.atom;
      if (atom.kind !== 0 || atom.text.length === 0) {
        continue;
      }
      const fontName = PdfBuiltinFont.resourceName(atom.fontKind, atom.bold, atom.italic);
      fonts.set(fontName, true);
      if (fontName !== lastFont || atom.sizePt !== lastSize) {
        content += '/' + fontName + ' ' + PdfBuilder.num(atom.sizePt) + ' Tf\n';
        lastFont = fontName;
        lastSize = atom.sizePt;
      }
      if (atom.color !== lastColor) {
        content += DocxToPdf.rgbOp(atom.color, true);
        lastColor = atom.color;
      }
      content += '1 0 0 1 ' + PdfBuilder.num(span.x) + ' ' +
        PdfBuilder.num(h - span.y) + ' Tm ' +
        PdfBuilder.hexString(atom.text, atom.cjk) + ' Tj\n';
    }
    content += 'ET\n';

    page.content = content;
    fonts.forEach((v: boolean, name: string) => {
      page.fonts.push(name);
    });
    page.images = images;
    return page;
  }

  /** 颜色运算符：rg 或 RG */
  private static rgbOp(color: number, fill: boolean): string {
    const r = ((color >> 16) & 0xff) / 255;
    const g = ((color >> 8) & 0xff) / 255;
    const b = (color & 0xff) / 255;
    const op = fill ? ' rg\n' : ' RG\n';
    return PdfBuilder.num(r) + ' ' + PdfBuilder.num(g) + ' ' + PdfBuilder.num(b) + op;
  }
}

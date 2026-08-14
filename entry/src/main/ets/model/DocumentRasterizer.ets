/**
 * 文档/图片 → RGB 位图。
 *
 * - 文本：用 OffscreenCanvas 排版并逐页栅格化（UTF-8 文本）。
 * - 图片：用 ImageSource 解码，按目标纸张等比缩放。
 */

import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { RgbImage } from './RasterImage';
import { XlsxSheet } from './OfficeParser';

export class DocumentRasterizer {

  /** 文本换行：按可用宽度贪心折行（兼容中文逐字、英文按空格）。 */
  private static wrapText(ctx: OffscreenCanvasRenderingContext2D, text: string, maxWidth: number): string[] {
    const lines: string[] = [];
    let line = '';
    for (let i = 0; i < text.length; i++) {
      const ch = text.charAt(i);
      if (ch === '\n') {
        lines.push(line);
        line = '';
        continue;
      }
      if (ch === '\r') {
        continue;
      }
      const candidate = line + ch;
      if (line.length > 0 && ctx.measureText(candidate).width > maxWidth) {
        let out = line;
        if (out.charAt(out.length - 1) === ' ') {
          out = out.substring(0, out.length - 1);
        }
        lines.push(out);
        line = (ch === ' ') ? '' : ch;
      } else {
        line = candidate;
      }
    }
    if (line.length > 0) {
      let out = line;
      if (out.charAt(out.length - 1) === ' ') {
        out = out.substring(0, out.length - 1);
      }
      lines.push(out);
    }
    return lines;
  }

  /**
   * 把纯文本排版成多页 RGB 位图。
   * @param content 文本内容
   * @param pageW 页面像素宽
   * @param pageH 页面像素高
   * @param fontSize 字号（px）
   * @param margin 页边距（px）
   */
  static async rasterizeText(content: string, pageW: number, pageH: number,
    fontSize: number, margin: number): Promise<RgbImage[]> {
    const pages: RgbImage[] = [];
    const lineHeight = Math.round(fontSize * 1.4);
    const maxWidth = pageW - margin * 2;
    const maxY = pageH - margin;

    const canvas = new OffscreenCanvas(pageW, pageH);
    const ctx = canvas.getContext('2d');
    ctx.font = fontSize + 'px sans-serif';

    const lines = DocumentRasterizer.wrapText(ctx, content, maxWidth);

    let y = margin;
    let pageHasContent = false;

    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, pageW, pageH);
    ctx.fillStyle = '#000000';
    ctx.textBaseline = 'top';

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (y + lineHeight > maxY) {
        // 换页：把当前页读出来
        if (pageHasContent) {
          const pm = ctx.getPixelMap(0, 0, pageW, pageH);
          const buf = new ArrayBuffer(pageW * pageH * 4);
          await pm.readPixelsToBuffer(buf);
          const rgba = new Uint8Array(buf);
          pages.push(RgbImage.fromRgba(pageW, pageH, rgba));
          pm.release();
        }
        ctx.fillStyle = '#ffffff';
        ctx.fillRect(0, 0, pageW, pageH);
        ctx.fillStyle = '#000000';
        y = margin;
        pageHasContent = false;
      }
      if (line.length > 0) {
        ctx.fillText(line, margin, y);
        pageHasContent = true;
      }
      y += lineHeight;
    }

    if (pageHasContent) {
      const pm = ctx.getPixelMap(0, 0, pageW, pageH);
      const buf = new ArrayBuffer(pageW * pageH * 4);
      await pm.readPixelsToBuffer(buf);
      const rgba = new Uint8Array(buf);
      pages.push(RgbImage.fromRgba(pageW, pageH, rgba));
      pm.release();
    }

    return pages;
  }

  /**
   * 解码图片并等比缩放到不超过 (maxW, maxH) 的 RGB 位图。
   */
  static async loadImageToRgb(uri: string, maxW: number, maxH: number): Promise<RgbImage> {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const source = image.createImageSource(file.fd);
      const info = await source.getImageInfo();
      const sw = info.size.width;
      const sh = info.size.height;
      let targetW = sw;
      let targetH = sh;
      const scale = Math.min(maxW / sw, maxH / sh);
      if (scale < 1) {
        targetW = Math.max(1, Math.round(sw * scale));
        targetH = Math.max(1, Math.round(sh * scale));
      }
      const pm = await source.createPixelMap({ desiredSize: { width: targetW, height: targetH } });
      const buf = new ArrayBuffer(targetW * targetH * 4);
      await pm.readPixelsToBuffer(buf);
      const rgba = new Uint8Array(buf);
      const result = RgbImage.fromRgba(targetW, targetH, rgba);
      pm.release();
      source.release();
      return result;
    } finally {
      fs.closeSync(file);
    }
  }

  /** 把内容位图居中放到整页白纸上（照片打印时居中）。 */
  static composeCentered(pageW: number, pageH: number, src: RgbImage): RgbImage {
    const dst = new RgbImage(pageW, pageH);
    dst.data.fill(255);
    const ox = Math.floor((pageW - src.width) / 2);
    const oy = Math.floor((pageH - src.height) / 2);
    for (let yy = 0; yy < src.height; yy++) {
      const so = yy * src.width * 3;
      const do_ = ((oy + yy) * pageW + ox) * 3;
      dst.data.set(src.data.subarray(so, so + src.width * 3), do_);
    }
    return dst;
  }

  private static async pageToRgb(ctx: OffscreenCanvasRenderingContext2D, w: number, h: number): Promise<RgbImage> {
    const pm = ctx.getPixelMap(0, 0, w, h);
    const buf = new ArrayBuffer(w * h * 4);
    await pm.readPixelsToBuffer(buf);
    const rgba = new Uint8Array(buf);
    const img = RgbImage.fromRgba(w, h, rgba);
    pm.release();
    return img;
  }

  /** 把 xlsx 表格渲染成带网格线的位图（自动分页） */
  static async rasterizeGrid(sheet: XlsxSheet, pageW: number, pageH: number,
    fontSize: number, margin: number): Promise<RgbImage[]> {
    const pages: RgbImage[] = [];
    const lineHeight = Math.round(fontSize * 1.35);
    const availW = pageW - margin * 2;
    const availH = pageH - margin * 2;
    const cols = Math.max(1, sheet.maxCols);
    const colW = Math.max(20, Math.floor(availW / cols));
    const pad = Math.max(2, Math.round(fontSize * 0.25));

    const canvas = new OffscreenCanvas(pageW, pageH);
    const ctx = canvas.getContext('2d');
    ctx.font = fontSize + 'px sans-serif';

    // 预换行 + 行高
    const wrapped: string[][][] = [];
    const rowHeights: number[] = [];
    for (let r = 0; r < sheet.maxRows; r++) {
      const rowCells: string[][] = [];
      let maxLines = 1;
      for (let c = 0; c < cols; c++) {
        const text = c < sheet.rows[r].length ? sheet.rows[r][c] : '';
        const lines = DocumentRasterizer.wrapText(ctx, text, colW - pad * 2);
        rowCells.push(lines);
        if (lines.length > maxLines) {
          maxLines = lines.length;
        }
      }
      wrapped.push(rowCells);
      const h = maxLines * lineHeight + pad * 2;
      rowHeights.push(Math.min(h, Math.round(availH * 0.8)));
    }

    let y = margin;
    let pageHasContent = false;
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, pageW, pageH);
    ctx.strokeStyle = '#999999';
    ctx.lineWidth = 1;
    ctx.fillStyle = '#000000';
    ctx.textBaseline = 'top';

    for (let r = 0; r < sheet.maxRows; r++) {
      const rh = rowHeights[r];
      if (y + rh > pageH - margin) {
        if (pageHasContent) {
          pages.push(await DocumentRasterizer.pageToRgb(ctx, pageW, pageH));
        }
        ctx.fillStyle = '#ffffff';
        ctx.fillRect(0, 0, pageW, pageH);
        ctx.strokeStyle = '#999999';
        ctx.fillStyle = '#000000';
        y = margin;
        pageHasContent = false;
      }
      for (let c = 0; c < cols; c++) {
        const x = margin + c * colW;
        ctx.strokeRect(x, y, colW, rh);
        const lines = wrapped[r][c];
        for (let li = 0; li < lines.length; li++) {
          ctx.fillText(lines[li], x + pad, y + pad + li * lineHeight);
        }
      }
      pageHasContent = true;
      y += rh;
    }

    if (pageHasContent) {
      pages.push(await DocumentRasterizer.pageToRgb(ctx, pageW, pageH));
    }
    return pages;
  }
}

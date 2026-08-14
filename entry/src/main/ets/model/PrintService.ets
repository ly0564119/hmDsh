/**
 * 打印服务：文档/图片 → RGB 光栅 → ESC/P-R 任务 → TCP 发送。
 */

import { PrinterConnection } from './PrinterConnection';
import { DocumentRasterizer } from './DocumentRasterizer';
import { RgbImage } from './RasterImage';
import { EscPrEncoder } from './EscPrEncoder';
import { Constants } from '../common/Constants';
import { ZipReader } from '../common/ZipReader';
import { OfficeParser } from './OfficeParser';
import { PdfRasterizer } from './PdfRasterizer';

export class PrintService {
  /** 打印纯文本，返回打印页数 */
  async printText(ip: string, content: string, dpi: number, paper: number,
    fontSizePx: number, marginPx: number): Promise<number> {
    const dims = EscPrEncoder.printablePx(dpi, paper);
    const pages = await DocumentRasterizer.rasterizeText(content, dims.width, dims.height,
      fontSizePx, marginPx);
    await this.sendPages(ip, pages, dpi, paper);
    return pages.length;
  }

  /** 打印照片（等比缩放并居中到纸张） */
  async printPhoto(ip: string, uri: string, dpi: number, paper: number): Promise<number> {
    const dims = EscPrEncoder.printablePx(dpi, paper);
    const img = await DocumentRasterizer.loadImageToRgb(uri, dims.width, dims.height);
    const page = DocumentRasterizer.composeCentered(dims.width, dims.height, img);
    const pages: RgbImage[] = [page];
    await this.sendPages(ip, pages, dpi, paper);
    return 1;
  }

  /** 打印 Word（.docx，提取纯文本） */
  async printDocx(ip: string, uri: string, dpi: number, paper: number,
    fontSizePx: number, marginPx: number): Promise<number> {
    const bytes = DocumentRasterizer.readFileBytes(uri);
    const xml = ZipReader.extractText(bytes, 'word/document.xml');
    const text = OfficeParser.docxToText(xml);
    if (text.trim().length === 0) {
      throw new Error('未能从 Word 文档中提取到文字');
    }
    return this.printText(ip, text, dpi, paper, fontSizePx, marginPx);
  }

  /** 打印 Excel（.xlsx，渲染为表格网格） */
  async printXlsx(ip: string, uri: string, dpi: number, paper: number,
    fontSizePx: number, marginPx: number): Promise<number> {
    const bytes = DocumentRasterizer.readFileBytes(uri);
    const sharedXml = ZipReader.extractText(bytes, 'xl/sharedStrings.xml');
    const shared = OfficeParser.parseSharedStrings(sharedXml);
    const sheetXml = ZipReader.extractText(bytes, 'xl/worksheets/sheet1.xml');
    const sheet = OfficeParser.parseSheet(sheetXml, shared);
    if (sheet.maxRows === 0) {
      throw new Error('未能从 Excel 中读取到数据');
    }
    const dims = EscPrEncoder.printablePx(dpi, paper);
    const pages = await DocumentRasterizer.rasterizeGrid(sheet, dims.width, dims.height,
      fontSizePx, marginPx);
    await this.sendPages(ip, pages, dpi, paper);
    return pages.length;
  }

  /** 打印 PDF（需 HarmonyOS 6.0 / API 14 的 PDF Kit） */
  async printPdf(ip: string, uri: string, dpi: number, paper: number, cacheDir: string): Promise<number> {
    const dims = EscPrEncoder.printablePx(dpi, paper);
    const rendered = await PdfRasterizer.renderPdf(uri, cacheDir, dims.width, dims.height);
    const pages: RgbImage[] = [];
    for (let i = 0; i < rendered.length; i++) {
      pages.push(DocumentRasterizer.composeCentered(dims.width, dims.height, rendered[i]));
    }
    await this.sendPages(ip, pages, dpi, paper);
    return pages.length;
  }

  private async sendPages(ip: string, pages: RgbImage[], dpi: number, paper: number): Promise<void> {
    if (pages.length === 0) {
      throw new Error('没有可打印的内容');
    }
    const job = EscPrEncoder.buildJob(pages, dpi, paper);
    const conn = new PrinterConnection();
    await conn.connect(ip, Constants.PORT);
    try {
      await conn.send(job);
    } finally {
      await conn.close();
    }
  }
}

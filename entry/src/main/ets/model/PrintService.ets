/**
 * 打印流程编排：文档/图片 → 排版 → 分带栅格化 → ESC/P-R → TCP 9100。
 *
 * 全流程流式：每渲染一个带就立刻发出去，不在内存里保留整页栅格，
 * 因此 A4 720dpi 这种上百 MB 的作业也能在手机上跑。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { Constants } from '../common/Constants';
import { Utf8 } from '../common/Utf8';
import { ZipArchive } from '../common/ZipReader';
import { DocumentRasterizer } from './DocumentRasterizer';
import { EscPrGeometry, EscPrJobOptions, EscPrJobWriter, PageDims } from './EscPrEncoder';
import { OfficeParser, XlsxSheet } from './OfficeParser';
import { PageContent } from './PageContent';
import { PageRenderer } from './PageRenderer';
import { PrinterConnection } from './PrinterConnection';
import { TextFont } from './TextFont';

/** 进度回调：把可读的进度文案回传给界面 */
export type PrintProgress = (message: string) => void;

/** 一次打印请求 */
export class PrintRequest {
  /** 打印机 IP */
  ip: string = '';
  /** ESC/P-R 作业参数（分辨率、纸张、介质、质量等） */
  options: EscPrJobOptions = new EscPrJobOptions();
  /** 正文字号（磅，1 磅 = 1/72 英寸） */
  fontSizePt: number = 11;
  /** 页内留白（毫米，在可打印区之内再留一圈） */
  marginMm: number = 8;
  /** 进度回调，可为 null */
  progress: PrintProgress | null = null;

  constructor(ip: string, options: EscPrJobOptions) {
    this.ip = ip;
    this.options = options;
  }

  /** 字号换算成当前分辨率下的像素 */
  fontSizePx(): number {
    return Math.max(6, Math.round(this.fontSizePt / 72 * this.options.dpi));
  }

  /** 留白换算成当前分辨率下的像素 */
  marginPx(): number {
    return Math.max(0, Math.round(this.marginMm / Constants.MM_PER_INCH * this.options.dpi));
  }

  notify(message: string): void {
    if (this.progress !== null) {
      this.progress(message);
    }
  }
}

export class PrintService {
  /** 单个待打印文件的大小上限，防止把内存打爆 */
  private static readonly MAX_FILE_BYTES: number = 64 * 1024 * 1024;

  /** 打印纯文本，返回打印页数 */
  async printText(req: PrintRequest, text: string): Promise<number> {
    if (text.trim().length === 0) {
      throw new Error('没有可打印的文字内容');
    }
    const size = PrintService.pageSize(req);
    const font = new TextFont(req.fontSizePx());
    req.notify('正在排版…');
    const pages = DocumentRasterizer.layoutText(text, font, size.width, size.height, req.marginPx());
    return await this.sendPages(req, pages, font);
  }

  /** 打印照片（等比缩放并居中到可打印区） */
  async printPhoto(req: PrintRequest, uri: string): Promise<number> {
    const size = PrintService.pageSize(req);
    req.notify('正在解码图片…');
    const page = await DocumentRasterizer.layoutPhoto(uri, size.width, size.height);
    const pages: PageContent[] = [page];
    const font = new TextFont(req.fontSizePx());
    try {
      return await this.sendPages(req, pages, font);
    } finally {
      page.release();
    }
  }

  /** 打印 Word（.docx，提取正文文字后按纯文本排版） */
  async printDocx(req: PrintRequest, uri: string): Promise<number> {
    req.notify('正在解析 Word 文档…');
    const archive = ZipArchive.open(PrintService.readBinaryFile(uri));
    const text = OfficeParser.docxToText(archive);
    if (text.trim().length === 0) {
      throw new Error('这个 Word 文档里没有可提取的文字（可能整篇是图片或文本框）');
    }
    return await this.printText(req, text);
  }

  /** 打印 Excel（.xlsx，渲染成带网格线的表格） */
  async printXlsx(req: PrintRequest, uri: string): Promise<number> {
    req.notify('正在解析 Excel 文档…');
    const archive = ZipArchive.open(PrintService.readBinaryFile(uri));
    const sheet: XlsxSheet = OfficeParser.xlsxToSheet(archive);
    if (sheet.maxRows === 0) {
      throw new Error('这个 Excel 里没有读到数据');
    }
    const size = PrintService.pageSize(req);
    const font = new TextFont(req.fontSizePx());
    req.notify('正在排版…');
    const pages = DocumentRasterizer.layoutGrid(sheet, font, size.width, size.height, req.marginPx());
    return await this.sendPages(req, pages, font);
  }

  /** 当前请求对应的页面（可打印区）像素尺寸 */
  private static pageSize(req: PrintRequest): PageDims {
    return new EscPrGeometry(req.options.dpi, req.options.paper).printableSize();
  }

  /**
   * 把排好版的页面发给打印机。
   * 逐页、逐带渲染并发送，任何一步失败都会关闭连接。
   */
  private async sendPages(req: PrintRequest, pages: PageContent[], font: TextFont): Promise<number> {
    if (pages.length === 0) {
      throw new Error('没有可打印的内容');
    }
    const conn = new PrinterConnection();
    req.notify('正在连接打印机…');
    await conn.connect(req.ip, Constants.PORT);
    try {
      const writer = new EscPrJobWriter(req.options, (chunk: Uint8Array) => conn.send(chunk));
      const size = writer.pageSize();
      const bandRows = PageRenderer.bandRows(size.width, size.height);
      const renderer = new PageRenderer(size.width, bandRows);

      await writer.start();
      for (let i = 0; i < pages.length; i++) {
        req.notify('正在打印第 ' + (i + 1) + '/' + pages.length + ' 页…');
        await writer.startPage(i + 1);
        for (let top = 0; top < size.height; top += bandRows) {
          const band = renderer.render(pages[i], font, top);
          await writer.writeBand(band, top);
        }
        await writer.endPage(pages.length - i - 1);
      }
      await writer.end();
      req.notify('数据已全部发送，打印机正在出纸…');
    } finally {
      await conn.close();
    }
    return pages.length;
  }

  /** 按 URI 读取整个文件（picker 返回的 URI 不能直接当路径用，必须先 open 拿 fd） */
  static readBinaryFile(uri: string): Uint8Array {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(file.fd).size;
      if (size <= 0) {
        throw new Error('文件是空的');
      }
      if (size > PrintService.MAX_FILE_BYTES) {
        throw new Error('文件过大（' + Math.round(size / 1024 / 1024) + 'MB），请拆分后再打印');
      }
      const out = new Uint8Array(size);
      const chunk = new ArrayBuffer(Math.min(size, 512 * 1024));
      const view = new Uint8Array(chunk);
      let pos = 0;
      while (pos < size) {
        const want = Math.min(chunk.byteLength, size - pos);
        const read = fs.readSync(file.fd, chunk, { offset: pos, length: want });
        if (read <= 0) {
          break;
        }
        out.set(view.subarray(0, read), pos);
        pos += read;
      }
      return pos === size ? out : out.subarray(0, pos);
    } finally {
      fs.closeSync(file);
    }
  }

  /** 按 URI 读取文本文件（UTF-8，自动跳过 BOM） */
  static readTextFile(uri: string): string {
    return Utf8.decode(PrintService.readBinaryFile(uri));
  }
}

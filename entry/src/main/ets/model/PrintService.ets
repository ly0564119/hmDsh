/**
 * 打印流程编排：文档/图片 → 解析 → 排版 → 预览 / 分带栅格化 → ESC/P-R → TCP 9100。
 *
 * 流程刻意分成三段，让「预览所见 = 打印所得」：
 *  1. loadXxx()：读文件并解析成 PrintSource（与打印设置无关，只做一次）；
 *  2. prepare()：按当前打印设置排版成 PrintJob（换纸张/分辨率要重新排版）；
 *  3. renderPreview() 预览、printJob() 发送——两者吃的是同一个 PrintJob。
 *
 * 发送阶段全程流式：每渲染一个带就立刻发出去，不在内存里保留整页栅格，
 * 因此 A4 720dpi 这种上百 MB 的作业也能在手机上跑。
 */

import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Constants } from '../common/Constants';
import { Utf8 } from '../common/Utf8';
import { ZipArchive } from '../common/ZipReader';
import { DocumentRasterizer } from './DocumentRasterizer';
import { EscPrGeometry, EscPrJobOptions, EscPrJobWriter } from './EscPrEncoder';
import { OfficeParser, XlsxSheet } from './OfficeParser';
import { PageContent } from './PageContent';
import { PagePreview, PageRenderer } from './PageRenderer';
import { PrinterConnection } from './PrinterConnection';
import { TextFont } from './TextFont';

/** 进度回调：把可读的进度文案回传给界面 */
export type PrintProgress = (message: string) => void;

/** 待打印内容的来源：已解析完成，可按不同打印设置反复排版 */
export class PrintSource {
  /** 纯文字（.txt 与 .docx 提取结果都归到这里） */
  static readonly KIND_TEXT: string = 'text';
  /** 表格（.xlsx） */
  static readonly KIND_SHEET: string = 'sheet';
  /** 照片 */
  static readonly KIND_PHOTO: string = 'photo';

  readonly kind: string;
  /** 界面上显示的名字（文件名或类型描述） */
  readonly displayName: string;
  readonly text: string;
  readonly sheet: XlsxSheet | null;
  readonly photoUri: string;

  private constructor(kind: string, displayName: string, text: string,
    sheet: XlsxSheet | null, photoUri: string) {
    this.kind = kind;
    this.displayName = displayName;
    this.text = text;
    this.sheet = sheet;
    this.photoUri = photoUri;
  }

  static ofText(displayName: string, text: string): PrintSource {
    return new PrintSource(PrintSource.KIND_TEXT, displayName, text, null, '');
  }

  static ofSheet(displayName: string, sheet: XlsxSheet): PrintSource {
    return new PrintSource(PrintSource.KIND_SHEET, displayName, '', sheet, '');
  }

  static ofPhoto(displayName: string, uri: string): PrintSource {
    return new PrintSource(PrintSource.KIND_PHOTO, displayName, '', null, uri);
  }
}

/** 排好版的打印作业：既能逐页预览，也能直接发给打印机 */
export class PrintJob {
  /** 各页内容（页面坐标，原点在可打印区左上角） */
  readonly pages: PageContent[];
  /** 排版所用字型 */
  readonly font: TextFont;
  /** 排版时的纸张几何，预览与打印一致性校验都靠它 */
  readonly geometry: EscPrGeometry;

  constructor(pages: PageContent[], font: TextFont, geometry: EscPrGeometry) {
    this.pages = pages;
    this.font = font;
    this.geometry = geometry;
  }

  get pageCount(): number {
    return this.pages.length;
  }

  /** 页面（可打印区）像素宽 */
  get pageWidth(): number {
    return this.geometry.printableWidth;
  }

  /** 页面（可打印区）像素高 */
  get pageHeight(): number {
    return this.geometry.printableHeight;
  }

  /** 释放各页持有的原生资源（照片 PixelMap），重新排版或退出预览时调用 */
  release(): void {
    for (let i = 0; i < this.pages.length; i++) {
      this.pages[i].release();
    }
  }
}

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

  /** 读取 .txt */
  static loadText(uri: string, displayName: string): PrintSource {
    const text = PrintService.readTextFile(uri);
    if (text.trim().length === 0) {
      throw new Error('文件内容为空');
    }
    return PrintSource.ofText(displayName, text);
  }

  /** 读取 .docx（提取正文文字） */
  static loadDocx(uri: string, displayName: string): PrintSource {
    const archive = ZipArchive.open(PrintService.readBinaryFile(uri));
    const text = OfficeParser.docxToText(archive);
    if (text.trim().length === 0) {
      throw new Error('这个 Word 文档里没有可提取的文字（可能整篇是图片或文本框）');
    }
    return PrintSource.ofText(displayName, text);
  }

  /** 读取 .xlsx（取第一个工作表） */
  static loadXlsx(uri: string, displayName: string): PrintSource {
    const archive = ZipArchive.open(PrintService.readBinaryFile(uri));
    const sheet: XlsxSheet = OfficeParser.xlsxToSheet(archive);
    if (sheet.maxRows === 0) {
      throw new Error('这个 Excel 里没有读到数据');
    }
    return PrintSource.ofSheet(displayName, sheet);
  }

  /** 照片：解码放到排版阶段做（换纸张要重新按目标尺寸解码） */
  static loadPhoto(uri: string, displayName: string): PrintSource {
    return PrintSource.ofPhoto(displayName, uri);
  }

  /**
   * 按当前打印设置排版。
   * 纸张、分辨率、留白任一项变化都要重新调用，预览与打印才会一致。
   */
  async prepare(req: PrintRequest, source: PrintSource): Promise<PrintJob> {
    const geometry = new EscPrGeometry(req.options.dpi, req.options.paper);
    const size = geometry.printableSize();
    const font = new TextFont(req.fontSizePx());
    let pages: PageContent[] = [];
    if (source.kind === PrintSource.KIND_PHOTO) {
      req.notify('正在解码图片…');
      pages = [await DocumentRasterizer.layoutPhoto(source.photoUri, size.width, size.height)];
    } else if (source.kind === PrintSource.KIND_SHEET) {
      req.notify('正在排版…');
      const sheet = source.sheet;
      if (sheet === null) {
        throw new Error('表格内容缺失');
      }
      pages = DocumentRasterizer.layoutGrid(sheet, font, size.width, size.height, req.marginPx());
    } else {
      req.notify('正在排版…');
      pages = DocumentRasterizer.layoutText(source.text, font, size.width, size.height, req.marginPx());
    }
    if (pages.length === 0) {
      throw new Error('没有可打印的内容');
    }
    return new PrintJob(pages, font, geometry);
  }

  /**
   * 渲染某一页的预览图。
   * @param pageIndex 页序号，从 0 开始
   * @param targetWidth 预览图宽度（像素）
   */
  static renderPreview(job: PrintJob, pageIndex: number, targetWidth: number): image.PixelMap {
    if (pageIndex < 0 || pageIndex >= job.pages.length) {
      throw new Error('预览页号超出范围');
    }
    return PagePreview.render(job.pages[pageIndex], job.font, job.geometry, targetWidth);
  }

  /**
   * 把排好版的作业发给打印机，返回打印页数。
   * 逐页、逐带渲染并发送，任何一步失败都会关闭连接。
   */
  async printJob(req: PrintRequest, job: PrintJob): Promise<number> {
    if (job.pageCount === 0) {
      throw new Error('没有可打印的内容');
    }
    const conn = new PrinterConnection();
    req.notify('正在连接打印机…');
    await conn.connect(req.ip, Constants.PORT);
    try {
      const writer = new EscPrJobWriter(req.options, (chunk: Uint8Array) => conn.send(chunk));
      const size = writer.pageSize();
      if (size.width !== job.pageWidth || size.height !== job.pageHeight) {
        // 预览之后又改了打印设置，排版结果已经对不上纸张了
        throw new Error('打印设置已变更，请重新预览后再打印');
      }
      const bandRows = PageRenderer.bandRows(size.width, size.height);
      const renderer = new PageRenderer(size.width, bandRows);

      await writer.start();
      for (let i = 0; i < job.pageCount; i++) {
        req.notify('正在打印第 ' + (i + 1) + '/' + job.pageCount + ' 页…');
        await writer.startPage(i + 1);
        for (let top = 0; top < size.height; top += bandRows) {
          const band = renderer.render(job.pages[i], job.font, top);
          await writer.writeBand(band, top);
        }
        await writer.endPage(job.pageCount - i - 1);
      }
      await writer.end();
      req.notify('数据已全部发送，打印机正在出纸…');
    } finally {
      await conn.close();
    }
    return job.pageCount;
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

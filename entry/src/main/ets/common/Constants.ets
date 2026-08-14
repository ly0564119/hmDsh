/**
 * 全局常量：纸张、分辨率、端口等。
 */

export class PaperSize {
  readonly name: string;
  readonly widthMm: number;
  readonly heightMm: number;

  constructor(name: string, widthMm: number, heightMm: number) {
    this.name = name;
    this.widthMm = widthMm;
    this.heightMm = heightMm;
  }
}

export class Constants {
  /** ESC/P-R 原始打印端口 */
  static readonly PORT: number = 9100;

  /** 文档默认分辨率（dpi） */
  static readonly DOC_DPI: number = 300;

  /** 照片默认分辨率（dpi） */
  static readonly PHOTO_DPI: number = 600;

  static readonly MM_PER_INCH: number = 25.4;

  static readonly PAPER_A4: PaperSize = new PaperSize('A4', 210, 297);
  static readonly PAPER_A5: PaperSize = new PaperSize('A5', 148, 210);
  static readonly PAPER_4x6: PaperSize = new PaperSize('4x6 英寸', 101.6, 152.4);
  static readonly PAPER_5x7: PaperSize = new PaperSize('5x7 英寸', 127, 177.8);

  /** 最大像素预算（约 1600 万像素），防止超大位图撑爆内存 */
  static readonly MAX_PIXELS: number = 16_000_000;

  /** 把毫米换算成指定 dpi 下的像素数 */
  static mmToPx(mm: number, dpi: number): number {
    return Math.round(mm / Constants.MM_PER_INCH * dpi);
  }
}

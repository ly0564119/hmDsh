/**
 * 全局常量：纸张规格、可打印边距、端口等。
 *
 * 说明：ESC/P-R 的 setj 命令要求主机自己算出「纸张像素尺寸 + 页边距 + 可打印区像素尺寸」，
 * 官方驱动是从机型能力数据里取边距的，我们无法在线查询，所以这里用爱普生喷墨机
 * 通用的保守边距：三边 3mm，普通纸底边 14mm（进纸机构决定，给小了会被裁切）。
 */

/** 纸张规格：物理尺寸 + 四边不可打印边距（单位 mm） */
export class PaperSpec {
  /** 界面显示名 */
  readonly name: string;
  readonly widthMm: number;
  readonly heightMm: number;
  readonly marginLeftMm: number;
  readonly marginTopMm: number;
  readonly marginRightMm: number;
  readonly marginBottomMm: number;

  constructor(name: string, widthMm: number, heightMm: number,
    marginLeftMm: number, marginTopMm: number, marginRightMm: number, marginBottomMm: number) {
    this.name = name;
    this.widthMm = widthMm;
    this.heightMm = heightMm;
    this.marginLeftMm = marginLeftMm;
    this.marginTopMm = marginTopMm;
    this.marginRightMm = marginRightMm;
    this.marginBottomMm = marginBottomMm;
  }
}

export class Constants {
  /** ESC/P-R 原始打印端口（RAW / JetDirect） */
  static readonly PORT: number = 9100;

  static readonly MM_PER_INCH: number = 25.4;

  /** 普通纸边距：左右上 3mm、下 14mm */
  private static readonly PLAIN_SIDE_MM: number = 3;
  private static readonly PLAIN_BOTTOM_MM: number = 14;

  /** A4（L805 支持的最大纸张） */
  static readonly PAPER_A4: PaperSpec = new PaperSpec('A4', 210, 297,
    Constants.PLAIN_SIDE_MM, Constants.PLAIN_SIDE_MM, Constants.PLAIN_SIDE_MM, Constants.PLAIN_BOTTOM_MM);

  static readonly PAPER_LETTER: PaperSpec = new PaperSpec('Letter', 215.9, 279.4,
    Constants.PLAIN_SIDE_MM, Constants.PLAIN_SIDE_MM, Constants.PLAIN_SIDE_MM, Constants.PLAIN_BOTTOM_MM);

  static readonly PAPER_A5: PaperSpec = new PaperSpec('A5', 148, 210,
    Constants.PLAIN_SIDE_MM, Constants.PLAIN_SIDE_MM, Constants.PLAIN_SIDE_MM, Constants.PLAIN_BOTTOM_MM);

  /** 明信片 100×148mm，照片纸走纸路径底边余量小，四边统一 3mm */
  static readonly PAPER_POSTCARD: PaperSpec = new PaperSpec('明信片 100×148', 100, 148, 3, 3, 3, 3);

  /** 4×6 英寸照片纸（101.6×152.4mm） */
  static readonly PAPER_4X6: PaperSpec = new PaperSpec('4×6 照片', 101.6, 152.4, 3, 3, 3, 3);

  /** 5×7 英寸照片纸（127×177.8mm） */
  static readonly PAPER_5X7: PaperSpec = new PaperSpec('5×7 照片', 127, 177.8, 3, 3, 3, 3);

  /** 位图最大像素预算，防止超大位图撑爆内存 */
  static readonly MAX_PIXELS: number = 16_000_000;

  /** 单个渲染带的目标字节数（RGBA），控制分带渲染的内存占用 */
  static readonly BAND_BYTES_BUDGET: number = 4 * 1024 * 1024;

  /** 累积多少字节就往 socket flush 一次 */
  static readonly SEND_CHUNK_BYTES: number = 128 * 1024;

  /** 把毫米换算成指定 dpi 下的像素数（向下取整，用于边距） */
  static mmToPxFloor(mm: number, dpi: number): number {
    return Math.floor(mm / Constants.MM_PER_INCH * dpi);
  }

  /** 把毫米换算成指定 dpi 下的像素数（向上取整，用于纸张尺寸） */
  static mmToPxCeil(mm: number, dpi: number): number {
    return Math.ceil(mm / Constants.MM_PER_INCH * dpi);
  }
}

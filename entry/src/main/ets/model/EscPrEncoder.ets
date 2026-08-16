/**
 * ESC/P-R（爱普生喷墨栅格协议）编码器，用于 L805 等 6 色照片打印机。
 *
 * 命令依据：Epson 官方开源驱动 epson-inkjet-printer-escpr 的
 * lib/epson-escpr-api.c（ESC/P-R 命令表、setj/setq 参数布局、RunLengthEncode），
 * 以及 ezrec/python-epson 的 escpr.py（同一套协议的独立实现，可交叉验证）。
 *
 * 关键点（旧实现踩过的坑）：
 *  - L805 是喷墨机，只认 ESC/P-R；GS(0x1D) 前缀的那套 `xxE` 命令属于
 *    ESC/PAGE-COLOR，是激光机语言。发给 L805 会被当成 ESC/P2 文本，
 *    于是整页打出乱码字符——这正是「图片打印出来是乱码」的原因。
 *  - ESC/P-R 命令格式：ESC + 分类(1B) + 参数长度(4B 小端) + 命令名(4B ASCII) + 参数。
 *    注意长度字段是小端，而参数里的坐标/尺寸是大端，两者不能混。
 *  - 栅格数据按「一行一条 dsnd 命令」发送，单条数据长度上限 0xFFFF 字节。
 *  - 进入 ESC/P-R 之前要先退出 IEEE-1284.4 包模式、ESC @ 初始化、
 *    再走一遍 REMOTE1 远程命令（作业开始、作业名、进纸口）。
 */

import { ByteWriter } from '../common/ByteWriter';
import { Constants, PaperSpec } from '../common/Constants';
import { RgbImage } from './RasterImage';

/** 输入分辨率（dpi）。喷墨机原生网格是 360 的倍数，L805 用 360/720 最稳。 */
export class EscPrDpi {
  /** 标准：360dpi */
  static readonly STANDARD: number = 360;
  /** 高质量：720dpi */
  static readonly HIGH: number = 720;

  /**
   * dpi → setj 命令里的 inputResolution 代码。
   * 官方驱动映射：360→0x00、720→0x01、300→0x02、600→0x03。
   */
  static toCode(dpi: number): number {
    if (dpi === 720) {
      return 0x01;
    }
    if (dpi === 300) {
      return 0x02;
    }
    if (dpi === 600) {
      return 0x03;
    }
    return 0x00; // 360dpi 及未知值都按 360 处理
  }
}

/** 打印质量（setq 的第 2 个参数） */
export class EscPrQuality {
  static readonly DRAFT: number = 0;
  static readonly NORMAL: number = 1;
  static readonly HIGH: number = 2;
}

/** 介质类型（setq 的第 1 个参数，取值来自官方 MTID 表） */
export class EscPrMediaType {
  /** 普通纸 */
  static readonly PLAIN: number = 0;
  /** 亚光纸 */
  static readonly MATTE: number = 5;
  /** 照片纸（光面） */
  static readonly PHOTO: number = 6;
  /** 高级光面照片纸 */
  static readonly PREMIUM_GLOSSY: number = 11;
}

/** 色彩模式（setq 的第 3 个参数） */
export class EscPrColorMode {
  static readonly COLOR: number = 0;
  static readonly MONOCHROME: number = 1;
}

/** 打印方向（setj 的最后一个参数） */
export class EscPrDirection {
  /** 双向打印，速度快 */
  static readonly BIDIRECTIONAL: number = 0;
  /** 单向打印，套准更准、更慢 */
  static readonly UNIDIRECTIONAL: number = 1;
}

/** 数据压缩方式（dsnd 的第 3 个参数） */
class EscPrCompression {
  static readonly NONE: number = 0;
  static readonly RLE: number = 1;
}

/** 尺寸（像素） */
export class PageDims {
  width: number = 0;
  height: number = 0;

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
  }
}

/** 一次打印作业的参数 */
export class EscPrJobOptions {
  /** 输入分辨率 */
  dpi: number = EscPrDpi.STANDARD;
  /** 纸张规格 */
  paper: PaperSpec = Constants.PAPER_A4;
  /** 介质类型 */
  mediaType: number = EscPrMediaType.PLAIN;
  /** 打印质量 */
  quality: number = EscPrQuality.NORMAL;
  /** 色彩模式 */
  colorMode: number = EscPrColorMode.COLOR;
  /** 打印方向 */
  direction: number = EscPrDirection.BIDIRECTIONAL;
  /** 是否对栅格行做 RLE 压缩（默认开，可大幅减少传输量） */
  compress: boolean = true;
  /** 作业名，会显示在打印机面板/任务列表里（ASCII，最长 8 字节） */
  jobName: string = 'HmPrint';
}

/** 纸张几何：纸张像素尺寸、页边距、可打印区尺寸，全部按指定 dpi 换算 */
export class EscPrGeometry {
  readonly paperWidth: number;
  readonly paperHeight: number;
  readonly marginLeft: number;
  readonly marginTop: number;
  readonly printableWidth: number;
  readonly printableHeight: number;

  constructor(dpi: number, paper: PaperSpec) {
    this.paperWidth = Constants.mmToPxCeil(paper.widthMm, dpi);
    this.paperHeight = Constants.mmToPxCeil(paper.heightMm, dpi);
    this.marginLeft = Constants.mmToPxFloor(paper.marginLeftMm, dpi);
    this.marginTop = Constants.mmToPxFloor(paper.marginTopMm, dpi);
    const marginRight = Constants.mmToPxFloor(paper.marginRightMm, dpi);
    const marginBottom = Constants.mmToPxFloor(paper.marginBottomMm, dpi);
    this.printableWidth = Math.max(1, this.paperWidth - this.marginLeft - marginRight);
    this.printableHeight = Math.max(1, this.paperHeight - this.marginTop - marginBottom);
  }

  /** 可打印区尺寸（也就是需要栅格化的页面尺寸） */
  printableSize(): PageDims {
    return new PageDims(this.printableWidth, this.printableHeight);
  }
}

/**
 * ESC/P-R 行程编码（RLE）。
 *
 * 编码单位是「像素」而不是字节：
 *  - 计数字节 0x00~0x7F：后面紧跟 (n + 1) 个像素的原始数据；
 *  - 计数字节 0x80~0xFF：后面 1 个像素重复 (257 - n) 次（即 2~129 次）。
 * 与官方驱动 RunLengthEncode() 一致，包括「压完反而更大就放弃压缩」的行为。
 */
export class EscPrRle {
  /** 比较 src 中两个像素是否相同 */
  private static samePixel(src: Uint8Array, a: number, b: number, bpp: number): boolean {
    for (let i = 0; i < bpp; i++) {
      if (src[a + i] !== src[b + i]) {
        return false;
      }
    }
    return true;
  }

  /**
   * 压缩一行像素。
   *
   * @param src 源数据
   * @param srcOffset 该行在 src 中的起始下标
   * @param pixels 该行像素数
   * @param bpp 每像素字节数（RGB888 为 3）
   * @param dst 输出缓冲，长度需 >= pixels * bpp
   * @returns 压缩后的字节数；若压缩后不小于原始大小则返回 -1（调用方改发原始数据）
   */
  static encodeRow(src: Uint8Array, srcOffset: number, pixels: number, bpp: number, dst: Uint8Array): number {
    const rowBytes = pixels * bpp;
    let s = srcOffset;
    let d = 0;
    let done = 0;

    while (done < pixels) {
      if (done + 1 < pixels && EscPrRle.samePixel(src, s, s + bpp, bpp)) {
        // 连续相同像素：最多压 129 个
        let rep = 2;
        while (done + rep < pixels && rep < 0x81 &&
          EscPrRle.samePixel(src, s + (rep - 1) * bpp, s + rep * bpp, bpp)) {
          rep++;
        }
        if (d + 1 + bpp > rowBytes) {
          return -1;
        }
        dst[d] = (0xff - rep + 2) & 0xff;
        d++;
        for (let i = 0; i < bpp; i++) {
          dst[d + i] = src[s + i];
        }
        d += bpp;
        s += rep * bpp;
        done += rep;
      } else {
        // 非重复像素：一次最多带 128 个原始像素
        let cnt = 1;
        while (done + cnt + 1 < pixels && cnt < 0x80 &&
          !EscPrRle.samePixel(src, s + cnt * bpp, s + (cnt + 1) * bpp, bpp)) {
          cnt++;
        }
        const bytes = cnt * bpp;
        if (d + 1 + bytes > rowBytes) {
          return -1;
        }
        dst[d] = (cnt - 1) & 0xff;
        d++;
        for (let i = 0; i < bytes; i++) {
          dst[d + i] = src[s + i];
        }
        d += bytes;
        s += bytes;
        done += cnt;
      }
    }
    return d;
  }
}

/** 打印数据出口：把一段字节交给打印机（通常是 TCP 9100） */
export type EscPrSink = (chunk: Uint8Array) => Promise<void>;

/**
 * ESC/P-R 作业写出器。
 *
 * 采用「边渲染边发送」的流式结构：调用方按渲染带（若干行）喂数据，
 * 内部攒够一定字节就 flush 到 sink。这样即使 A4 720dpi（整页 RGB 上百 MB）
 * 也不需要在内存里放整页栅格。
 */
export class EscPrJobWriter {
  private static readonly ESC: number = 0x1b;
  /** 单条 dsnd 的栅格数据长度字段是 2 字节，因此上限 0xFFFF */
  private static readonly MAX_ROW_BYTES: number = 0xffff;

  private readonly opts: EscPrJobOptions;
  private readonly geo: EscPrGeometry;
  private readonly sink: EscPrSink;
  private readonly w: ByteWriter = new ByteWriter(Constants.SEND_CHUNK_BYTES * 2);
  /** RLE 输出临时缓冲，按行长度惰性分配 */
  private rleBuf: Uint8Array = new Uint8Array(0);
  /** 当前页已发送到的行号，用于校验行序 */
  private currentPageRow: number = 0;
  private pageOpened: boolean = false;

  constructor(opts: EscPrJobOptions, sink: EscPrSink) {
    this.opts = opts;
    this.geo = new EscPrGeometry(opts.dpi, opts.paper);
    this.sink = sink;
  }

  /** 本作业需要的页面栅格尺寸 */
  pageSize(): PageDims {
    return this.geo.printableSize();
  }

  /** 写 ESC/P-R 命令头：ESC + 分类 + 参数长度(4B 小端) + 命令名(4B) */
  private cmdHeader(cls: string, name: string, paramLength: number): void {
    this.w.writeByte(EscPrJobWriter.ESC);
    this.w.writeAscii(cls);
    this.w.writeU32LE(paramLength);
    this.w.writeAscii(name);
  }

  /**
   * 写 REMOTE1 远程命令：命令名(2B) + 长度(2B 小端) + 0x00 + 参数。
   * 长度字段把那个固定的 0x00 也算进去，所以是 params.length + 1。
   */
  private remoteCmd(name: string, params: number[]): void {
    this.w.writeAscii(name);
    this.w.writeU16LE(params.length + 1);
    this.w.writeByte(0x00);
    for (let i = 0; i < params.length; i++) {
      this.w.writeByte(params[i]);
    }
  }

  /** 退出 IEEE-1284.4 包模式（USB 与网络口都建议先发，避免打印机停在包模式） */
  private writeExitPacketMode(): void {
    this.w.writeByte(0x00);
    this.w.writeByte(0x00);
    this.w.writeByte(0x00);
    this.w.writeByte(EscPrJobWriter.ESC);
    this.w.writeByte(0x01);
    this.w.writeAscii('@EJL 1284.4\n@EJL     \n');
  }

  /** ESC @：初始化打印机 */
  private writeInitPrinter(): void {
    this.w.writeByte(EscPrJobWriter.ESC);
    this.w.writeByte(0x40);
  }

  /** 进入 REMOTE1 远程模式：ESC ( R 08 00 00 "REMOTE1" */
  private writeEnterRemoteMode(): void {
    this.w.writeByte(EscPrJobWriter.ESC);
    this.w.writeAscii('(R');
    this.w.writeU16LE(8);
    this.w.writeByte(0x00);
    this.w.writeAscii('REMOTE1');
  }

  /** 退出远程模式：ESC 00 00 00 */
  private writeExitRemoteMode(): void {
    this.w.writeByte(EscPrJobWriter.ESC);
    this.w.writeByte(0x00);
    this.w.writeByte(0x00);
    this.w.writeByte(0x00);
  }

  /** 进入 ESC/P-R 栅格模式：ESC ( R 06 00 00 "ESCPR" */
  private writeEnterEscPrMode(): void {
    this.w.writeByte(EscPrJobWriter.ESC);
    this.w.writeAscii('(R');
    this.w.writeU16LE(6);
    this.w.writeByte(0x00);
    this.w.writeAscii('ESCPR');
  }

  /** 远程命令 TI：告诉打印机当前时间（作业时间戳） */
  private writeRemoteTime(): void {
    const now = new Date();
    const year = now.getFullYear();
    this.remoteCmd('TI', [
      (year >>> 8) & 0xff, year & 0xff,
      now.getMonth() + 1,
      now.getDate(),
      now.getHours(),
      now.getMinutes(),
      now.getSeconds()
    ]);
  }

  /** 远程命令 JH：作业名（固定 8 字节 ASCII，不足补空格） */
  private writeRemoteJobHeader(): void {
    const params: number[] = [0x00, 0x00, 0x00, 0x00, 0x00];
    const name = this.opts.jobName.length > 0 ? this.opts.jobName : 'HmPrint';
    for (let i = 0; i < 8; i++) {
      const code = i < name.length ? name.charCodeAt(i) : 0x20;
      params.push(code > 0x7e || code < 0x20 ? 0x20 : code);
    }
    this.remoteCmd('JH', params);
  }

  /** setq：介质类型 / 质量 / 色彩，共 9 字节参数（无调色板） */
  private writePrintQuality(): void {
    this.cmdHeader('q', 'setq', 9);
    this.w.writeByte(this.opts.mediaType);
    this.w.writeByte(this.opts.quality);
    this.w.writeByte(this.opts.colorMode);
    this.w.writeByte(0x00); // 亮度 0
    this.w.writeByte(0x00); // 对比度 0
    this.w.writeByte(0x00); // 饱和度 0
    this.w.writeByte(0x00); // colorPlane = 0：RGB 全彩栅格
    this.w.writeU16BE(0);   // 调色板长度 0
  }

  /** setj：纸张与可打印区（22 字节参数，注意都是大端） */
  private writeJobSize(): void {
    this.cmdHeader('j', 'setj', 22);
    this.w.writeU32BE(this.geo.paperWidth);
    this.w.writeU32BE(this.geo.paperHeight);
    this.w.writeU16BE(this.geo.marginTop);
    this.w.writeU16BE(this.geo.marginLeft);
    this.w.writeU32BE(this.geo.printableWidth);
    this.w.writeU32BE(this.geo.printableHeight);
    this.w.writeByte(EscPrDpi.toCode(this.opts.dpi));
    this.w.writeByte(this.opts.direction);
  }

  /** 作业开始：包模式退出 → 初始化 → 远程命令 → 进入 ESC/P-R → 质量/纸张 */
  async start(): Promise<void> {
    this.writeExitPacketMode();
    this.writeInitPrinter();
    this.writeEnterRemoteMode();
    this.writeRemoteTime();
    this.remoteCmd('JS', [0x00, 0x00, 0x00]);   // 作业开始
    this.writeRemoteJobHeader();
    this.remoteCmd('PP', [0x01, 0xff]);         // 进纸口：自动选择
    this.writeExitRemoteMode();
    this.writeEnterEscPrMode();
    this.writePrintQuality();
    this.writeJobSize();
    await this.flush(true);
  }

  /**
   * 开始一页。
   * @param pageNumber 页号，从 1 开始（协议里 setn 只有 1 字节，超过 99 按 99 发）
   */
  async startPage(pageNumber: number): Promise<void> {
    this.cmdHeader('p', 'sttp', 0);
    const n = pageNumber < 1 ? 1 : (pageNumber > 99 ? 99 : pageNumber);
    this.cmdHeader('p', 'setn', 1);
    this.w.writeByte(n);
    this.pageOpened = true;
    this.currentPageRow = 0;
    await this.flush(false);
  }

  /**
   * 发送一个渲染带（band）的栅格行。
   *
   * @param band 该带的 RGB 位图，宽度必须等于页面可打印宽度
   * @param bandTop 该带首行在页面中的 y 坐标
   */
  async writeBand(band: RgbImage, bandTop: number): Promise<void> {
    if (!this.pageOpened) {
      throw new Error('请先调用 startPage() 再发送栅格数据');
    }
    if (band.width !== this.geo.printableWidth) {
      throw new Error('栅格宽度(' + band.width + ')与可打印宽度(' +
        this.geo.printableWidth + ')不一致');
    }
    const rowBytes = band.rowBytes;
    if (rowBytes > EscPrJobWriter.MAX_ROW_BYTES) {
      throw new Error('单行栅格 ' + rowBytes + ' 字节超出 ESC/P-R 上限，请降低分辨率');
    }
    if (this.opts.compress && this.rleBuf.length < rowBytes) {
      this.rleBuf = new Uint8Array(rowBytes);
    }

    for (let r = 0; r < band.height; r++) {
      const y = bandTop + r;
      if (y >= this.geo.printableHeight) {
        break; // 超出可打印高度的行直接丢弃，避免打印机报错
      }
      const srcOffset = band.rowOffset(r);
      let compression = EscPrCompression.NONE;
      let dataLength = rowBytes;
      if (this.opts.compress) {
        const packed = EscPrRle.encodeRow(band.data, srcOffset, band.width, 3, this.rleBuf);
        if (packed > 0) {
          compression = EscPrCompression.RLE;
          dataLength = packed;
        }
      }

      // dsnd 参数：x 偏移(2B BE) + y 偏移(2B BE) + 压缩方式(1B) + 数据长度(2B BE) + 数据
      this.cmdHeader('d', 'dsnd', 7 + dataLength);
      this.w.writeU16BE(0);
      this.w.writeU16BE(y);
      this.w.writeByte(compression);
      this.w.writeU16BE(dataLength);
      if (compression === EscPrCompression.RLE) {
        this.w.writeSlice(this.rleBuf, 0, dataLength);
      } else {
        this.w.writeSlice(band.data, srcOffset, dataLength);
      }
      this.currentPageRow = y + 1;
      await this.flush(false);
    }
  }

  /**
   * 结束一页。
   * @param remainingPages 本页之后还剩几页（0 表示这是最后一页，打印机会出纸收尾）
   */
  async endPage(remainingPages: number): Promise<void> {
    const rest = remainingPages < 0 ? 0 : (remainingPages > 99 ? 99 : remainingPages);
    this.cmdHeader('p', 'endp', 1);
    this.w.writeByte(rest);
    this.pageOpened = false;
    await this.flush(true);
  }

  /** 结束作业：endj → ESC @ → 远程 JE → 退出远程模式 */
  async end(): Promise<void> {
    this.cmdHeader('j', 'endj', 0);
    this.writeInitPrinter();
    this.writeEnterRemoteMode();
    this.remoteCmd('JE', []);
    this.writeExitRemoteMode();
    await this.flush(true);
  }

  /** 攒够 SEND_CHUNK_BYTES（或强制）时把缓冲写给 sink */
  private async flush(force: boolean): Promise<void> {
    if (this.w.length === 0) {
      return;
    }
    if (!force && this.w.length < Constants.SEND_CHUNK_BYTES) {
      return;
    }
    const chunk = this.w.takeBytes();
    await this.sink(chunk);
  }
}

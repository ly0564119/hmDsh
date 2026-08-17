/**
 * PDF 图像解码（纯逻辑部分）：把图像 XObject 的采样数据展开成 RGBA 像素。
 *
 * 支持的组合：
 *  - 位深 1 / 2 / 4 / 8 / 16；
 *  - 颜色空间 DeviceGray / DeviceRGB / DeviceCMYK / Indexed / ICCBased / Separation（近似）；
 *  - /Decode 反色数组；
 *  - /ImageMask 1 位蒙版（用当前填充色上色，未涂的地方透明）；
 *  - /SMask 与 /Mask（蒙版流按 alpha 处理，颜色键蒙版按范围置透明）。
 *
 * JPEG（DCTDecode）与 JPEG2000 不在这里解码——交给系统图片解码器，
 * 本模块只负责判断「要不要走平台解码」并给出原始字节。
 *
 * 另外提供按整数步长的降采样：手机上打印 A4 720dpi 时，
 * 一张 6000×4000 的图没必要全解到内存里，按需要的像素数抽样即可。
 */

import { PdfColorSpace } from './PdfColorSpace';
import { PdfDocument } from './PdfDocument';
import { PdfImageFilter } from './PdfFilters';
import { PdfObj } from './PdfObject';

/** 图像的基本信息 */
export class PdfImageInfo {
  width: number = 0;
  height: number = 0;
  bitsPerComponent: number = 8;
  /** 颜色空间（ImageMask 时无意义） */
  space: PdfColorSpace = PdfColorSpace.deviceGray();
  isMask: boolean = false;
  /** /Decode 数组，空表示默认 */
  decode: number[] = [];
  /** 还剩下的图像过滤器（DCTDecode 等），空串表示数据已完全解码 */
  imageFilter: string = '';
  /** 已解码（或仍是 JPEG 编码）的数据 */
  data: Uint8Array = new Uint8Array(0);
}

/** 解码后的位图：RGBA8888，alpha 为 255 表示不透明 */
export class PdfDecodedImage {
  readonly width: number;
  readonly height: number;
  readonly rgba: Uint8Array;

  constructor(width: number, height: number, rgba: Uint8Array) {
    this.width = width;
    this.height = height;
    this.rgba = rgba;
  }
}

export class PdfImageDecoder {
  /** 读取图像基本信息 */
  static describe(doc: PdfDocument, stream: PdfObj): PdfImageInfo {
    const info = new PdfImageInfo();
    info.width = Math.trunc(doc.numberOf(stream, 'Width', 0));
    info.height = Math.trunc(doc.numberOf(stream, 'Height', 0));
    info.isMask = doc.dictGet(stream, 'ImageMask').asBool(false);
    info.bitsPerComponent = info.isMask
      ? 1 : Math.trunc(doc.numberOf(stream, 'BitsPerComponent', 8));
    if (!info.isMask) {
      info.space = PdfColorSpace.parse(doc, stream.get('ColorSpace'), PdfObj.NULL_OBJ);
    }
    const decodeArr = doc.dictGet(stream, 'Decode').asArray();
    for (let i = 0; i < decodeArr.length; i++) {
      info.decode.push(doc.resolve(decodeArr[i]).asNumber(0));
    }
    const result = doc.decodeImageStream(stream);
    info.imageFilter = result.imageFilter;
    info.data = result.data;
    return info;
  }

  /** 该图像是否需要平台解码器（JPEG / JPEG2000） */
  static needsPlatformDecode(info: PdfImageInfo): boolean {
    return info.imageFilter === PdfImageFilter.DCT || info.imageFilter === PdfImageFilter.JPX;
  }

  /**
   * 展开成 RGBA。
   *
   * @param doc 文档（读 SMask / Mask 需要）
   * @param stream 图像流对象
   * @param info describe() 的结果
   * @param maskColor ImageMask 的上色颜色 0xRRGGBB
   * @param maxPixels 目标像素预算，超过就按整数步长抽样
   * @returns 位图；无法解码（需要平台解码器或数据不足）返回 null
   */
  static toRgba(doc: PdfDocument, stream: PdfObj, info: PdfImageInfo,
    maskColor: number, maxPixels: number): PdfDecodedImage | null {
    if (info.width <= 0 || info.height <= 0 || PdfImageDecoder.needsPlatformDecode(info)) {
      return null;
    }
    if (info.imageFilter.length > 0) {
      return null; // CCITT / JBIG2 等未支持的编码
    }
    const comps = info.isMask ? 1 : Math.max(1, info.space.components);
    const bpc = info.bitsPerComponent;
    const rowBits = info.width * comps * bpc;
    const rowBytes = Math.ceil(rowBits / 8);
    if (info.data.length < rowBytes) {
      return null;
    }
    // 数据不完整时按实际行数来（部分文档的最后一行会被截断）
    const availableRows = Math.floor(info.data.length / rowBytes);
    const srcHeight = Math.min(info.height, Math.max(1, availableRows));

    // 降采样步长
    let step = 1;
    if (maxPixels > 0) {
      while (Math.ceil(info.width / step) * Math.ceil(srcHeight / step) > maxPixels) {
        step++;
      }
    }
    const outWidth = Math.max(1, Math.ceil(info.width / step));
    const outHeight = Math.max(1, Math.ceil(srcHeight / step));
    const rgba = new Uint8Array(outWidth * outHeight * 4);

    const maxValue = (1 << bpc) - 1;
    const decode = info.decode;
    const hasDecode = decode.length >= comps * 2;
    const maskR = (maskColor >> 16) & 0xff;
    const maskG = (maskColor >> 8) & 0xff;
    const maskB = maskColor & 0xff;
    const values: number[] = [];
    for (let i = 0; i < comps; i++) {
      values.push(0);
    }

    for (let oy = 0; oy < outHeight; oy++) {
      const sy = Math.min(srcHeight - 1, oy * step);
      const rowStart = sy * rowBytes;
      for (let ox = 0; ox < outWidth; ox++) {
        const sx = Math.min(info.width - 1, ox * step);
        const out = (oy * outWidth + ox) * 4;
        if (info.isMask) {
          // 1 = 不涂（默认），Decode [1 0] 时反过来
          let bit = PdfImageDecoder.sampleAt(info.data, rowStart, sx, 0, 1, 1);
          if (hasDecode && decode[0] === 1) {
            bit = 1 - bit;
          }
          if (bit === 0) {
            rgba[out] = maskR;
            rgba[out + 1] = maskG;
            rgba[out + 2] = maskB;
            rgba[out + 3] = 255;
          } else {
            rgba[out + 3] = 0;
          }
          continue;
        }
        for (let c = 0; c < comps; c++) {
          let raw = PdfImageDecoder.sampleAt(info.data, rowStart, sx, c, comps, bpc);
          if (info.space.kind === PdfColorSpace.INDEXED) {
            if (hasDecode) {
              const dmin = decode[0];
              const dmax = decode[1];
              raw = dmin + raw * (dmax - dmin) / maxValue;
            }
            values[c] = raw;
          } else {
            let v = raw / maxValue;
            if (hasDecode) {
              const dmin = decode[c * 2];
              const dmax = decode[c * 2 + 1];
              v = dmin + v * (dmax - dmin);
            }
            values[c] = info.space.kind === PdfColorSpace.LAB && c === 0 ? v * 100 : v;
          }
        }
        const rgb = info.space.kind === PdfColorSpace.INDEXED
          ? info.space.indexedToRgb(Math.round(values[0]))
          : info.space.toRgb(values);
        rgba[out] = (rgb >> 16) & 0xff;
        rgba[out + 1] = (rgb >> 8) & 0xff;
        rgba[out + 2] = rgb & 0xff;
        rgba[out + 3] = 255;
      }
    }

    PdfImageDecoder.applyAlpha(doc, stream, info, rgba, outWidth, outHeight);
    return new PdfDecodedImage(outWidth, outHeight, rgba);
  }

  /**
   * 取一个采样值。
   * @param rowStart 行起始字节
   * @param x 列
   * @param comp 分量序号
   * @param comps 分量总数
   * @param bpc 位深
   */
  private static sampleAt(data: Uint8Array, rowStart: number, x: number,
    comp: number, comps: number, bpc: number): number {
    if (bpc === 8) {
      const idx = rowStart + x * comps + comp;
      return idx < data.length ? data[idx] : 0;
    }
    if (bpc === 16) {
      const idx = rowStart + (x * comps + comp) * 2;
      // 16 位取高字节（打印用 8 位足够）
      return idx < data.length ? data[idx] : 0;
    }
    const bitPos = (x * comps + comp) * bpc;
    const byteIdx = rowStart + (bitPos >> 3);
    if (byteIdx >= data.length) {
      return 0;
    }
    const shift = 8 - bpc - (bitPos & 7);
    return (data[byteIdx] >> shift) & ((1 << bpc) - 1);
  }

  /** 应用 /SMask（灰度 alpha）或 /Mask（蒙版流 / 颜色键） */
  private static applyAlpha(doc: PdfDocument, stream: PdfObj, info: PdfImageInfo,
    rgba: Uint8Array, width: number, height: number): void {
    const smask = doc.dictGet(stream, 'SMask');
    if (smask.isStream()) {
      PdfImageDecoder.applyMaskStream(doc, smask, rgba, width, height, false);
      return;
    }
    const mask = doc.dictGet(stream, 'Mask');
    if (mask.isStream()) {
      PdfImageDecoder.applyMaskStream(doc, mask, rgba, width, height, true);
      return;
    }
    if (mask.isArray()) {
      PdfImageDecoder.applyColorKeyMask(doc, mask.asArray(), info, rgba, width, height);
    }
  }

  /**
   * 用蒙版流改 alpha。
   * @param stencil true 表示 /Mask（1 位模板，1 = 遮住），false 表示 /SMask（灰度 = alpha）
   */
  private static applyMaskStream(doc: PdfDocument, maskStream: PdfObj, rgba: Uint8Array,
    width: number, height: number, stencil: boolean): void {
    const maskInfo = PdfImageDecoder.describe(doc, maskStream);
    if (maskInfo.width <= 0 || maskInfo.height <= 0 || maskInfo.imageFilter.length > 0) {
      return; // JPEG 编码的蒙版这里不处理（少见）
    }
    const bpc = maskInfo.bitsPerComponent;
    const rowBytes = Math.ceil(maskInfo.width * bpc / 8);
    if (maskInfo.data.length < rowBytes) {
      return;
    }
    const maxValue = (1 << bpc) - 1;
    const invert = maskInfo.decode.length >= 2 && maskInfo.decode[0] === 1;
    for (let y = 0; y < height; y++) {
      // 蒙版尺寸可能和图像不同，按比例最近邻取样
      const my = Math.min(maskInfo.height - 1, Math.floor(y * maskInfo.height / height));
      const rowStart = my * rowBytes;
      if (rowStart >= maskInfo.data.length) {
        break;
      }
      for (let x = 0; x < width; x++) {
        const mx = Math.min(maskInfo.width - 1, Math.floor(x * maskInfo.width / width));
        let v = PdfImageDecoder.sampleAt(maskInfo.data, rowStart, mx, 0, 1, bpc);
        if (invert) {
          v = maxValue - v;
        }
        const out = (y * width + x) * 4 + 3;
        if (stencil) {
          rgba[out] = v === 0 ? 255 : 0; // 模板蒙版：1 表示被遮住
        } else {
          rgba[out] = bpc === 8 ? v : Math.round(v * 255 / maxValue);
        }
      }
    }
  }

  /** 颜色键蒙版：采样值落在给定范围内的像素变透明 */
  private static applyColorKeyMask(doc: PdfDocument, ranges: PdfObj[], info: PdfImageInfo,
    rgba: Uint8Array, width: number, height: number): void {
    const comps = Math.max(1, info.space.components);
    if (ranges.length < comps * 2) {
      return;
    }
    const bounds: number[] = [];
    for (let i = 0; i < ranges.length; i++) {
      bounds.push(doc.resolve(ranges[i]).asNumber(0));
    }
    const bpc = info.bitsPerComponent;
    const rowBytes = Math.ceil(info.width * comps * bpc / 8);
    const stepX = info.width / width;
    const stepY = info.height / height;
    for (let y = 0; y < height; y++) {
      const sy = Math.min(info.height - 1, Math.floor(y * stepY));
      const rowStart = sy * rowBytes;
      for (let x = 0; x < width; x++) {
        const sx = Math.min(info.width - 1, Math.floor(x * stepX));
        let masked = true;
        for (let c = 0; c < comps; c++) {
          const v = PdfImageDecoder.sampleAt(info.data, rowStart, sx, c, comps, bpc);
          if (v < bounds[c * 2] || v > bounds[c * 2 + 1]) {
            masked = false;
            break;
          }
        }
        if (masked) {
          rgba[(y * width + x) * 4 + 3] = 0;
        }
      }
    }
  }
}

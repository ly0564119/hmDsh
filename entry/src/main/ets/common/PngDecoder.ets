/**
 * 轻量 PNG 解码：把常见的 Word 内嵌 PNG 转成 RGB888，供写入 PDF 图像对象。
 *
 * 只覆盖打印真正会遇到的子集：
 *  - 非隔行扫描；
 *  - 8 位色深；
 *  - 颜色类型 0（灰度）/ 2（RGB）/ 3（索引）/ 4（灰度+透明）/ 6（RGBA）。
 * 16 位、隔行、Adam7 遇到就放弃（调用方跳过该图），避免为一小部分图片写完整解码器。
 *
 * 滤波还原与 PDF 的 PNG 预测器是同一套算法（见 PdfFilters.applyPredictor）。
 */

import { Inflate } from './Inflate';
import { PdfFilters, PdfPredictorParams } from '../pdf/PdfFilters';

/** PNG 解码结果：未压缩的 RGB 像素 */
export class PngRgb {
  readonly width: number;
  readonly height: number;
  readonly rgb: Uint8Array;

  constructor(width: number, height: number, rgb: Uint8Array) {
    this.width = width;
    this.height = height;
    this.rgb = rgb;
  }
}

export class PngDecoder {
  /** PNG 文件头 */
  private static readonly SIG: number[] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

  /** 是否是 PNG（只看文件头，不解码） */
  static isPng(data: Uint8Array): boolean {
    if (data.length < 8) {
      return false;
    }
    for (let i = 0; i < 8; i++) {
      if (data[i] !== PngDecoder.SIG[i]) {
        return false;
      }
    }
    return true;
  }

  /**
   * 只读 IHDR 拿像素尺寸，不解码像素。
   * 解析 Word 图片时若缺少 wp:extent，用这个按 96dpi 估显示尺寸。
   */
  static size(data: Uint8Array): number[] | null {
    if (!PngDecoder.isPng(data) || data.length < 24) {
      return null;
    }
    const width = PngDecoder.readU32(data, 16);
    const height = PngDecoder.readU32(data, 20);
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) {
      return null;
    }
    return [width, height];
  }

  /**
   * 解码。
   * @returns RGB 位图；格式不支持或数据损坏返回 null
   */
  static decode(data: Uint8Array): PngRgb | null {
    if (!PngDecoder.isPng(data)) {
      return null;
    }
    let width = 0;
    let height = 0;
    let bitDepth = 0;
    let colorType = 0;
    let palette: Uint8Array | null = null;
    const idatParts: Uint8Array[] = [];
    let pos = 8;
    while (pos + 12 <= data.length) {
      const len = PngDecoder.readU32(data, pos);
      if (pos + 12 + len > data.length) {
        break;
      }
      const type = PngDecoder.readType(data, pos + 4);
      const payload = data.subarray(pos + 8, pos + 8 + len);
      if (type === 'IHDR') {
        if (payload.length < 13) {
          return null;
        }
        width = PngDecoder.readU32(payload, 0);
        height = PngDecoder.readU32(payload, 4);
        bitDepth = payload[8];
        colorType = payload[9];
        if (payload[10] !== 0 || payload[11] !== 0 || payload[12] !== 0) {
          return null; // 压缩方法/滤波方法必须是 0，隔行扫描不支持
        }
      } else if (type === 'PLTE') {
        palette = payload;
      } else if (type === 'IDAT') {
        idatParts.push(payload);
      } else if (type === 'IEND') {
        break;
      }
      pos += 12 + len;
    }
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) {
      return null;
    }
    if (bitDepth !== 8) {
      return null;
    }
    const compressed = PngDecoder.concat(idatParts);
    if (compressed.length < 2) {
      return null;
    }
    let filtered: Uint8Array;
    try {
      filtered = PdfFilters.flate(compressed);
    } catch (e) {
      try {
        filtered = Inflate.inflateRaw(compressed, 2, compressed.length - 2, 0);
      } catch (e2) {
        return null;
      }
    }
    const channels = PngDecoder.channelsOf(colorType);
    if (channels <= 0) {
      return null;
    }
    const params = new PdfPredictorParams();
    params.predictor = 15;
    params.colors = channels;
    params.bitsPerComponent = 8;
    params.columns = width;
    const raw = PdfFilters.applyPredictor(filtered, params);
    const expected = width * height * channels;
    if (raw.length < expected) {
      return null;
    }
    const rgb = new Uint8Array(width * height * 3);
    if (colorType === 2) {
      rgb.set(raw.subarray(0, rgb.length));
    } else if (colorType === 6) {
      for (let i = 0, o = 0; i < expected; i += 4, o += 3) {
        rgb[o] = raw[i];
        rgb[o + 1] = raw[i + 1];
        rgb[o + 2] = raw[i + 2];
      }
    } else if (colorType === 0) {
      for (let i = 0, o = 0; i < expected; i++, o += 3) {
        rgb[o] = raw[i];
        rgb[o + 1] = raw[i];
        rgb[o + 2] = raw[i];
      }
    } else if (colorType === 4) {
      for (let i = 0, o = 0; i < expected; i += 2, o += 3) {
        rgb[o] = raw[i];
        rgb[o + 1] = raw[i];
        rgb[o + 2] = raw[i];
      }
    } else if (colorType === 3) {
      if (palette === null) {
        return null;
      }
      for (let i = 0, o = 0; i < expected; i++, o += 3) {
        const idx = raw[i] * 3;
        rgb[o] = idx < palette.length ? palette[idx] : 0;
        rgb[o + 1] = idx + 1 < palette.length ? palette[idx + 1] : 0;
        rgb[o + 2] = idx + 2 < palette.length ? palette[idx + 2] : 0;
      }
    }
    return new PngRgb(width, height, rgb);
  }

  private static channelsOf(colorType: number): number {
    if (colorType === 0) {
      return 1;
    }
    if (colorType === 2) {
      return 3;
    }
    if (colorType === 3) {
      return 1;
    }
    if (colorType === 4) {
      return 2;
    }
    if (colorType === 6) {
      return 4;
    }
    return 0;
  }

  private static concat(parts: Uint8Array[]): Uint8Array {
    let total = 0;
    for (let i = 0; i < parts.length; i++) {
      total += parts[i].length;
    }
    const out = new Uint8Array(total);
    let at = 0;
    for (let i = 0; i < parts.length; i++) {
      out.set(parts[i], at);
      at += parts[i].length;
    }
    return out;
  }

  private static readU32(data: Uint8Array, offset: number): number {
    return ((data[offset] << 24) | (data[offset + 1] << 16) |
      (data[offset + 2] << 8) | data[offset + 3]) >>> 0;
  }

  private static readType(data: Uint8Array, offset: number): string {
    return String.fromCharCode(data[offset], data[offset + 1],
      data[offset + 2], data[offset + 3]);
  }
}

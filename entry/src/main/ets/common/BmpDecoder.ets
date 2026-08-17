/**
 * 轻量 BMP 解码：Word 里偶尔会内嵌未压缩的位图（截图、从旧文档粘贴）。
 *
 * 只覆盖打印会遇到的子集：
 *  - BITMAPINFOHEADER（40 字节信息头）；
 *  - 8 位调色板 / 24 位 BGR / 32 位 BGRA；
 *  - 自下而上（height>0）或自上而下（height<0）。
 * 压缩 BMP（RLE4/RLE8）和 16 位色遇到就放弃。
 */

import { PngRgb } from './PngDecoder';

export class BmpDecoder {
  /**
   * 解码 BMP。
   * @returns RGB 位图；不是 BMP 或不支持的变体返回 null
   */
  static decode(data: Uint8Array): PngRgb | null {
    const size = BmpDecoder.size(data);
    if (size === null) {
      return null;
    }
    const width = size[0];
    const height = size[1];
    const bits = data[28] | (data[29] << 8);
    const compression = BmpDecoder.readU32(data, 30);
    if (compression !== 0) {
      return null;
    }
    let dataOffset = BmpDecoder.readU32(data, 10);
    if (dataOffset < 54 || dataOffset >= data.length) {
      return null;
    }
    const dibSize = BmpDecoder.readU32(data, 14);
    const rawHeight = BmpDecoder.readI32(data, 22);
    const topDown = rawHeight < 0;
    const rowStride = Math.trunc((width * bits + 31) / 32) * 4;
    const rgb = new Uint8Array(width * height * 3);
    if (bits === 24 || bits === 32) {
      const bpp = bits === 24 ? 3 : 4;
      for (let y = 0; y < height; y++) {
        const srcY = topDown ? y : (height - 1 - y);
        const row = dataOffset + srcY * rowStride;
        for (let x = 0; x < width; x++) {
          const s = row + x * bpp;
          const d = (y * width + x) * 3;
          if (s + 2 >= data.length) {
            return null;
          }
          rgb[d] = data[s + 2];
          rgb[d + 1] = data[s + 1];
          rgb[d + 2] = data[s];
        }
      }
      return new PngRgb(width, height, rgb);
    }
    if (bits === 8) {
      const paletteOffset = 14 + dibSize;
      for (let y = 0; y < height; y++) {
        const srcY = topDown ? y : (height - 1 - y);
        const row = dataOffset + srcY * rowStride;
        for (let x = 0; x < width; x++) {
          if (row + x >= data.length) {
            return null;
          }
          const idx = data[row + x];
          const pal = paletteOffset + idx * 4;
          const d = (y * width + x) * 3;
          if (pal + 2 >= data.length) {
            return null;
          }
          rgb[d] = data[pal + 2];
          rgb[d + 1] = data[pal + 1];
          rgb[d + 2] = data[pal];
        }
      }
      return new PngRgb(width, height, rgb);
    }
    return null;
  }

  /** 读 BMP 像素尺寸，失败返回 null */
  static size(data: Uint8Array): number[] | null {
    if (data.length < 54) {
      return null;
    }
    if (data[0] !== 0x42 || data[1] !== 0x4d) {
      return null;
    }
    const dibSize = BmpDecoder.readU32(data, 14);
    if (dibSize < 40) {
      return null;
    }
    const width = BmpDecoder.readI32(data, 18);
    const height = Math.abs(BmpDecoder.readI32(data, 22));
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) {
      return null;
    }
    return [width, height];
  }

  private static readU32(data: Uint8Array, offset: number): number {
    return (data[offset] | (data[offset + 1] << 8) |
      (data[offset + 2] << 16)) + data[offset + 3] * 0x1000000;
  }

  private static readI32(data: Uint8Array, offset: number): number {
    const v = BmpDecoder.readU32(data, offset);
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }
}

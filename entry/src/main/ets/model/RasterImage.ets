/**
 * RGB 位图容器（8bit/通道，连续 RGB 排列）。
 */

export class RgbImage {
  width: number = 0;
  height: number = 0;
  /** 长度 = width * height * 3，按 RGB 顺序 */
  data: Uint8Array = new Uint8Array(0);

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
    this.data = new Uint8Array(width * height * 3);
  }

  /** 把 RGBA（含 alpha）数据转换成 RGB 位图；白色背景按 alpha 混合 */
  static fromRgba(width: number, height: number, rgba: Uint8Array): RgbImage {
    const img = new RgbImage(width, height);
    const n = width * height;
    for (let i = 0; i < n; i++) {
      const s = i * 4;
      const d = i * 3;
      const a = rgba[s + 3];
      if (a === 0) {
        img.data[d] = 255;
        img.data[d + 1] = 255;
        img.data[d + 2] = 255;
      } else if (a === 255) {
        img.data[d] = rgba[s];
        img.data[d + 1] = rgba[s + 1];
        img.data[d + 2] = rgba[s + 2];
      } else {
        // 与白色背景做 alpha 混合
        const af = a / 255;
        img.data[d] = Math.round(rgba[s] * af + 255 * (1 - af));
        img.data[d + 1] = Math.round(rgba[s + 1] * af + 255 * (1 - af));
        img.data[d + 2] = Math.round(rgba[s + 2] * af + 255 * (1 - af));
      }
    }
    return img;
  }

  /** 读取 (x, y) 的 RGB，写入 out 数组（长度 >= 3） */
  getPixel(x: number, y: number, out: number[]): void {
    const o = (y * this.width + x) * 3;
    out[0] = this.data[o];
    out[1] = this.data[o + 1];
    out[2] = this.data[o + 2];
  }

  setPixel(x: number, y: number, r: number, g: number, b: number): void {
    const o = (y * this.width + x) * 3;
    this.data[o] = r;
    this.data[o + 1] = g;
    this.data[o + 2] = b;
  }
}

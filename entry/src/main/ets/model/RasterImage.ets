/**
 * RGB 位图容器（8bit/通道，连续 RGB888 排列），既用于整页，也用于「渲染带」。
 *
 * ESC/P-R 的 dsnd 命令要求每行是 RGB888 裸数据，所以这里统一按
 * width * height * 3 的紧凑排列存放，不做行对齐。
 */

export class RgbImage {
  width: number = 0;
  height: number = 0;
  /** 长度 = width * height * 3，按 R、G、B 顺序 */
  data: Uint8Array = new Uint8Array(0);

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
    this.data = new Uint8Array(width * height * 3);
  }

  /** 第 y 行在 data 中的起始下标 */
  rowOffset(y: number): number {
    return y * this.width * 3;
  }

  /** 每行字节数 */
  get rowBytes(): number {
    return this.width * 3;
  }

  /**
   * 把 32 位像素缓冲（RGBA_8888 或 BGRA_8888）转换成 RGB 位图。
   *
   * 两个必须由调用方给准的参数：
   *  - srcStride：PixelMap 的行字节数可能带对齐填充，按 width*4 硬算会让图像斜掉；
   *  - bgra：各版本 readPixelsToBuffer 读出的通道顺序不完全一致，
   *    由 PixelOrder 在运行时探测一次后传进来，避免红蓝互换。
   * alpha 不为 255 的像素按「与白纸混合」处理，避免半透明文字发灰发黑。
   *
   * @param width 宽（像素）
   * @param height 高（像素）
   * @param pixels 32 位像素数据
   * @param srcStride 源缓冲每行字节数（>= width * 4）
   * @param bgra true 表示内存顺序是 B、G、R、A
   */
  static fromPixelBuffer(width: number, height: number, pixels: Uint8Array,
    srcStride: number, bgra: boolean): RgbImage {
    const img = new RgbImage(width, height);
    const dst = img.data;
    const stride = srcStride >= width * 4 ? srcStride : width * 4;
    const ri = bgra ? 2 : 0;
    const bi = bgra ? 0 : 2;
    for (let y = 0; y < height; y++) {
      let s = y * stride;
      let d = y * width * 3;
      for (let x = 0; x < width; x++) {
        const a = pixels[s + 3];
        if (a === 255) {
          dst[d] = pixels[s + ri];
          dst[d + 1] = pixels[s + 1];
          dst[d + 2] = pixels[s + bi];
        } else if (a === 0) {
          dst[d] = 255;
          dst[d + 1] = 255;
          dst[d + 2] = 255;
        } else {
          // 与白色背景做 alpha 混合
          const af = a / 255;
          const inv = 255 * (1 - af);
          dst[d] = Math.round(pixels[s + ri] * af + inv);
          dst[d + 1] = Math.round(pixels[s + 1] * af + inv);
          dst[d + 2] = Math.round(pixels[s + bi] * af + inv);
        }
        s += 4;
        d += 3;
      }
    }
    return img;
  }
}

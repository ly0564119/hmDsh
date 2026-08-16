/**
 * 打印用字型：封装 ArkGraphics2D 的 drawing.Font，提供字宽测量与行高计算。
 *
 * 之所以用 drawing 而不是 Canvas 组件：drawing 的坐标与字号都是**物理像素**，
 * 而 Canvas / OffscreenCanvas 默认按 vp 计量，会被屏幕密度缩放，
 * 打印这种「必须精确到点」的场景一旦被缩放，页面尺寸和像素缓冲长度就对不上了。
 */

import { drawing } from '@kit.ArkGraphics2D';

export class TextFont {
  /** 底层字型对象 */
  readonly font: drawing.Font;
  /** 字号（物理像素） */
  readonly sizePx: number;
  /** 基线以上高度 */
  private ascentPx: number = 0;
  /** 基线以下高度 */
  private descentPx: number = 0;
  /** 单字宽度缓存：中文文档里重复字很多，缓存能显著减少测量开销 */
  private widthCache: Map<string, number> = new Map();

  constructor(sizePx: number) {
    this.sizePx = sizePx;
    this.font = new drawing.Font();
    this.font.setSize(sizePx);
    try {
      const metrics = this.font.getMetrics();
      // drawing 的 ascent 是负值（基线以上），descent 为正值
      this.ascentPx = Math.abs(metrics.ascent);
      this.descentPx = Math.abs(metrics.descent);
    } catch (e) {
      this.ascentPx = 0;
      this.descentPx = 0;
    }
    if (this.ascentPx <= 0 || this.ascentPx > sizePx * 3) {
      this.ascentPx = sizePx * 0.82;
    }
    if (this.descentPx <= 0 || this.descentPx > sizePx * 3) {
      this.descentPx = sizePx * 0.22;
    }
  }

  /** 基线以上高度（像素） */
  get ascent(): number {
    return this.ascentPx;
  }

  /** 基线以下高度（像素） */
  get descent(): number {
    return this.descentPx;
  }

  /** 建议行高（含行间距） */
  get lineHeight(): number {
    return Math.ceil((this.ascentPx + this.descentPx) * 1.18);
  }

  /**
   * 取 text 中下标 i 处一个「完整字符」的长度：
   * 代理对（emoji 等增补平面字符）算 2，其余算 1。
   * 排版与绘制必须用同一套切分，否则宽度累加会和实际画出来的错位。
   */
  static charLengthAt(text: string, i: number): number {
    const code = text.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        return 2;
      }
    }
    return 1;
  }

  /**
   * 单个字符的前进宽度。
   * measureSingleCharacter 在当前字体缺字时会自动退化到系统字体测量，
   * 中英混排、生僻字都能拿到正确宽度。
   */
  charWidth(ch: string): number {
    const cached = this.widthCache.get(ch);
    if (cached !== undefined) {
      return cached;
    }
    let w = 0;
    try {
      if (ch.length === 1) {
        w = this.font.measureSingleCharacter(ch);
      } else {
        w = this.font.measureText(ch, drawing.TextEncoding.TEXT_ENCODING_UTF8);
      }
    } catch (e) {
      w = this.sizePx * 0.5;
    }
    if (!(w > 0)) {
      w = this.sizePx * 0.5;
    }
    this.widthCache.set(ch, w);
    return w;
  }
}

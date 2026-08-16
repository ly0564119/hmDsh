/**
 * 页面栅格化：把 PageContent 按「渲染带」画成 RGB 位图。
 *
 * 用 ArkGraphics2D 的 drawing 直接画到自建的 PixelMap 上：
 *  - 所有坐标/字号都是物理像素，不受屏幕密度影响（打印必须精确到点）；
 *  - PixelMap 由我们自己按 RGBA_8888 创建，读回的缓冲长度完全可控；
 *  - 一次只画 bandRows 行，内存占用与页面高度无关。
 */

import { common2D, drawing } from '@kit.ArkGraphics2D';
import { image } from '@kit.ImageKit';
import { Constants } from '../common/Constants';
import { PageContent, TextLine, LineSeg } from './PageContent';
import { RgbImage } from './RasterImage';
import { TextFont } from './TextFont';

/**
 * 探测 readPixelsToBuffer 读出的通道顺序。
 *
 * 各版本/机型上它可能是 RGBA 也可能是 BGRA，猜错会让照片红蓝互换。
 * 这里画一个纯红的 2×2 位图再读回来，用实际字节判断顺序，只探测一次。
 */
class PixelOrder {
  private static detected: boolean = false;
  private static bgra: boolean = false;

  static isBgra(): boolean {
    if (PixelOrder.detected) {
      return PixelOrder.bgra;
    }
    PixelOrder.detected = true;
    try {
      const size = 2;
      const initial = new ArrayBuffer(size * size * 4);
      new Uint8Array(initial).fill(255);
      const opts: image.InitializationOptions = {
        editable: true,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        srcPixelFormat: image.PixelMapFormat.RGBA_8888,
        size: { width: size, height: size }
      };
      const pm = image.createPixelMapSync(initial, opts);
      const canvas = new drawing.Canvas(pm);
      const brush = new drawing.Brush();
      const red: common2D.Color = { alpha: 255, red: 255, green: 0, blue: 0 };
      brush.setColor(red);
      canvas.attachBrush(brush);
      canvas.drawRect(0, 0, size, size);
      canvas.detachBrush();

      const out = new ArrayBuffer(size * size * 4);
      pm.readPixelsToBufferSync(out);
      const v = new Uint8Array(out);
      if (v[2] > 200 && v[0] < 60) {
        PixelOrder.bgra = true;
      } else {
        PixelOrder.bgra = false;
      }
      pm.release();
    } catch (e) {
      PixelOrder.bgra = false;
    }
    return PixelOrder.bgra;
  }
}

/**
 * 渲染带渲染器：固定宽度 + 固定行数，缓冲复用。
 * 每页新建一个实例，逐带调用 render()。
 */
export class PageRenderer {
  /** 页面（可打印区）宽度 */
  readonly width: number;
  /** 每带行数 */
  readonly rows: number;

  /** 初始白底缓冲，createPixelMapSync 会拷走，因此可以一直复用 */
  private readonly whiteBuffer: ArrayBuffer;
  /** 读回像素用的缓冲，首次渲染时按 PixelMap 实际字节数分配 */
  private readBuffer: ArrayBuffer | null = null;
  private readView: Uint8Array | null = null;
  /** PixelMap 的实际行字节数（可能带对齐填充） */
  private stride: number = 0;
  private readonly initOptions: image.InitializationOptions;
  private readonly sampling: drawing.SamplingOptions;
  /** 文字画刷（黑色，开抗锯齿） */
  private readonly textBrush: drawing.Brush;
  /** 网格线画笔（灰色细线） */
  private readonly gridPen: drawing.Pen;

  constructor(width: number, rows: number) {
    this.width = width;
    this.rows = rows;
    this.whiteBuffer = new ArrayBuffer(width * rows * 4);
    new Uint8Array(this.whiteBuffer).fill(255);
    this.initOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: width, height: rows }
    };
    this.sampling = new drawing.SamplingOptions(drawing.FilterMode.FILTER_MODE_LINEAR);

    this.textBrush = new drawing.Brush();
    const black: common2D.Color = { alpha: 255, red: 0, green: 0, blue: 0 };
    this.textBrush.setColor(black);
    this.textBrush.setAntiAlias(true);

    this.gridPen = new drawing.Pen();
    const gray: common2D.Color = { alpha: 255, red: 120, green: 120, blue: 120 };
    this.gridPen.setColor(gray);
    this.gridPen.setStrokeWidth(Math.max(1, Math.round(width / 1200)));
  }

  /** 按页面宽度算出合适的每带行数，让单带内存约等于预算值 */
  static bandRows(width: number, pageHeight: number): number {
    const byWidth = Math.floor(Constants.BAND_BYTES_BUDGET / Math.max(1, width * 4));
    let rows = byWidth;
    if (rows < 16) {
      rows = 16;
    }
    if (rows > 512) {
      rows = 512;
    }
    if (rows > pageHeight) {
      rows = pageHeight;
    }
    return rows;
  }

  /**
   * 渲染 [bandTop, bandTop + rows) 这一带。
   * @returns 该带的 RGB 位图（宽 = width，高 = rows）
   */
  render(content: PageContent, font: TextFont, bandTop: number): RgbImage {
    const pm = image.createPixelMapSync(this.whiteBuffer, this.initOptions);
    try {
      const canvas = new drawing.Canvas(pm);
      // 把画布原点上移到该带起点，之后一律用页面坐标绘制，超出部分自动裁掉
      canvas.translate(0, -bandTop);
      const bandBottom = bandTop + this.rows;

      this.drawImage(canvas, content, bandTop, bandBottom);
      this.drawStrokes(canvas, content, bandTop, bandBottom);
      this.drawTexts(canvas, content, font, bandTop, bandBottom);

      this.prepareReadBuffer(pm);
      const buffer = this.readBuffer as ArrayBuffer;
      const view = this.readView as Uint8Array;
      pm.readPixelsToBufferSync(buffer);
      return RgbImage.fromPixelBuffer(this.width, this.rows, view, this.stride, PixelOrder.isBgra());
    } finally {
      pm.release();
    }
  }

  /**
   * 首次渲染时按 PixelMap 的真实字节数与行跨度分配读回缓冲。
   * PixelMap 的行字节数可能大于 width*4（内存对齐），必须按实际 stride 取像素。
   */
  private prepareReadBuffer(pm: image.PixelMap): void {
    if (this.readBuffer !== null) {
      return;
    }
    const compact = this.width * 4;
    let bytes = 0;
    try {
      bytes = pm.getPixelBytesNumber();
    } catch (e) {
      bytes = 0;
    }
    if (bytes < compact * this.rows) {
      bytes = compact * this.rows;
    }
    let stride = 0;
    try {
      stride = pm.getImageInfoSync().stride;
    } catch (e) {
      stride = 0;
    }
    if (stride < compact || stride * this.rows > bytes) {
      stride = compact;
    }
    this.stride = stride;
    this.readBuffer = new ArrayBuffer(bytes);
    this.readView = new Uint8Array(this.readBuffer);
  }

  /** 画照片（整张图一次性交给画布，由画布做缩放与裁剪） */
  private drawImage(canvas: drawing.Canvas, content: PageContent,
    bandTop: number, bandBottom: number): void {
    const box = content.imageBox;
    if (box === null) {
      return;
    }
    if (box.top + box.height < bandTop || box.top > bandBottom) {
      return;
    }
    const dst: common2D.Rect = {
      left: box.left,
      top: box.top,
      right: box.left + box.width,
      bottom: box.top + box.height
    };
    canvas.drawImageRect(box.pixelMap, dst, this.sampling);
  }

  /** 画表格网格线 */
  private drawStrokes(canvas: drawing.Canvas, content: PageContent,
    bandTop: number, bandBottom: number): void {
    if (content.strokes.length === 0) {
      return;
    }
    canvas.attachPen(this.gridPen);
    for (let i = 0; i < content.strokes.length; i++) {
      const s: LineSeg = content.strokes[i];
      const minY = Math.min(s.y0, s.y1);
      const maxY = Math.max(s.y0, s.y1);
      if (maxY < bandTop || minY > bandBottom) {
        continue;
      }
      canvas.drawLine(s.x0, s.y0, s.x1, s.y1);
    }
    canvas.detachPen();
  }

  /** 画文字：逐字绘制，缺字时由系统字体兜底（中文/生僻字不会漏字） */
  private drawTexts(canvas: drawing.Canvas, content: PageContent, font: TextFont,
    bandTop: number, bandBottom: number): void {
    if (content.texts.length === 0) {
      return;
    }
    canvas.attachBrush(this.textBrush);
    for (let i = 0; i < content.texts.length; i++) {
      const line: TextLine = content.texts[i];
      // 只画与本带有交集的行
      if (line.baselineY + font.descent < bandTop || line.baselineY - font.ascent > bandBottom) {
        continue;
      }
      let x = line.x;
      const text = line.text;
      let p = 0;
      while (p < text.length) {
        const len = TextFont.charLengthAt(text, p);
        const ch = text.substring(p, p + len);
        p += len;
        const w = font.charWidth(ch);
        if (ch !== ' ') {
          try {
            if (len === 1) {
              canvas.drawSingleCharacter(ch, font.font, x, line.baselineY);
            } else {
              const blob = drawing.TextBlob.makeFromString(ch, font.font,
                drawing.TextEncoding.TEXT_ENCODING_UTF8);
              canvas.drawTextBlob(blob, x, line.baselineY);
            }
          } catch (e) {
            // 个别字符画不出来就跳过，不能让整个打印任务失败
          }
        }
        x += w;
      }
    }
    canvas.detachBrush();
  }
}

/**
 * 页面内容模型：一页要画什么，用「与设备无关的页面像素坐标」描述。
 *
 * 排版（DocumentRasterizer / PdfPageLayout）只产出这个模型，真正的像素绘制
 * 由 PageRenderer 按渲染带（band）分块完成。这样整页栅格不必同时驻留内存。
 *
 * 文本 / 表格走 texts + strokes + imageBox（旧路径）；
 * PDF 走 ops（按绘制顺序交错的文字、矢量、图片），避免叠放次序丢失。
 */

import { image } from '@kit.ImageKit';

/** 一行文本（纯文本 / Excel 用，单字体单颜色） */
export class TextLine {
  /** 行首 x（页面坐标） */
  x: number = 0;
  /** 文字基线 y（页面坐标） */
  baselineY: number = 0;
  text: string = '';

  constructor(x: number, baselineY: number, text: string) {
    this.x = x;
    this.baselineY = baselineY;
    this.text = text;
  }
}

/** 一条直线（表格网格线） */
export class LineSeg {
  x0: number = 0;
  y0: number = 0;
  x1: number = 0;
  y1: number = 0;

  constructor(x0: number, y0: number, x1: number, y1: number) {
    this.x0 = x0;
    this.y0 = y0;
    this.x1 = x1;
    this.y1 = y1;
  }
}

/** 一张图片在页面上的摆放位置 */
export class ImageBox {
  pixelMap: image.PixelMap;
  left: number = 0;
  top: number = 0;
  width: number = 0;
  height: number = 0;

  constructor(pixelMap: image.PixelMap, left: number, top: number, width: number, height: number) {
    this.pixelMap = pixelMap;
    this.left = left;
    this.top = top;
    this.width = width;
    this.height = height;
  }
}

/** 绘制指令类型 */
export class DrawKind {
  static readonly TEXT: number = 0;
  static readonly PATH: number = 1;
  static readonly IMAGE: number = 2;
}

/** 路径指令码（与 PdfPathOp 相同，避免 pdf 模块反向依赖 model） */
export class PathOp {
  static readonly MOVE: number = 0;
  static readonly LINE: number = 1;
  static readonly CUBIC: number = 2;
  static readonly CLOSE: number = 3;
}

/**
 * 一段带样式的文字。
 * advances 是每个完整字符的前进宽度（页面像素），渲染时按这个走，
 * 不自己测量，才能和 PDF 原排版对齐。
 */
export class StyledText {
  x: number = 0;
  y: number = 0;
  text: string = '';
  sizePx: number = 12;
  advances: number[] = [];
  rotationDeg: number = 0;
  color: number = 0;
  bold: boolean = false;
  italic: boolean = false;
  serif: boolean = false;
  monospace: boolean = false;
}

/** 一条矢量路径（填充 / 描边） */
export class PathShape {
  cmds: number[] = [];
  hasFill: boolean = false;
  fillColor: number = 0;
  evenOdd: boolean = false;
  hasStroke: boolean = false;
  strokeColor: number = 0;
  strokeWidth: number = 1;
}

/** 一条绘制指令（PDF 页按此顺序画） */
export class DrawOp {
  readonly kind: number;
  text: StyledText | null = null;
  path: PathShape | null = null;
  image: ImageBox | null = null;

  constructor(kind: number) {
    this.kind = kind;
  }

  static ofText(text: StyledText): DrawOp {
    const op = new DrawOp(DrawKind.TEXT);
    op.text = text;
    return op;
  }

  static ofPath(path: PathShape): DrawOp {
    const op = new DrawOp(DrawKind.PATH);
    op.path = path;
    return op;
  }

  static ofImage(image: ImageBox): DrawOp {
    const op = new DrawOp(DrawKind.IMAGE);
    op.image = image;
    return op;
  }
}

/** 一页的全部绘制内容 */
export class PageContent {
  /** 文本行（纯文本 / Excel） */
  texts: TextLine[] = [];
  /** 网格线（Excel） */
  strokes: LineSeg[] = [];
  /** 照片（单图居中） */
  imageBox: ImageBox | null = null;
  /**
   * PDF 绘制列表。非空时 PageRenderer 按这个顺序画，忽略上面三个字段。
   * 文字、色块、图片交错存放，叠放次序与 PDF 一致。
   */
  ops: DrawOp[] = [];

  /** 释放页面持有的原生资源（图片 PixelMap） */
  release(): void {
    if (this.imageBox !== null) {
      this.imageBox.pixelMap.release();
      this.imageBox = null;
    }
    for (let i = 0; i < this.ops.length; i++) {
      const img = this.ops[i].image;
      if (img !== null) {
        img.pixelMap.release();
        this.ops[i].image = null;
      }
    }
  }
}

/**
 * PDF 页面显示列表：内容流解释之后、真正画像素之前的中间表示。
 *
 * 坐标系统一为「页面点（pt）+ y 轴向下 + 原点在页面左上角」，
 * 并且已经把页面的 /Rotate 旋转与 CropBox 偏移吃掉了。
 * 好处是这一层与打印分辨率、纸张无关，换纸张/换分辨率不用重新解析内容流，
 * 光栅化时只要乘一个「像素/点」的比例即可。
 *
 * 元素按绘制顺序放在同一个数组里（PDF 里图片、矢量、文字是交错绘制的，
 * 分成三个数组会把叠放次序弄丢，比如白底色块会盖掉先画的文字）。
 */

import { PdfObj } from './PdfObject';

/** 2×3 仿射矩阵：[a b c d e f]，x' = a·x + c·y + e，y' = b·x + d·y + f */
export class PdfMatrix {
  a: number = 1;
  b: number = 0;
  c: number = 0;
  d: number = 1;
  e: number = 0;
  f: number = 0;

  constructor(a: number, b: number, c: number, d: number, e: number, f: number) {
    this.a = a;
    this.b = b;
    this.c = c;
    this.d = d;
    this.e = e;
    this.f = f;
  }

  static identity(): PdfMatrix {
    return new PdfMatrix(1, 0, 0, 1, 0, 0);
  }

  clone(): PdfMatrix {
    return new PdfMatrix(this.a, this.b, this.c, this.d, this.e, this.f);
  }

  /** this × m（先应用 this 再应用 m，与 PDF 的 `cm` 语义一致） */
  multiply(m: PdfMatrix): PdfMatrix {
    return new PdfMatrix(
      this.a * m.a + this.b * m.c,
      this.a * m.b + this.b * m.d,
      this.c * m.a + this.d * m.c,
      this.c * m.b + this.d * m.d,
      this.e * m.a + this.f * m.c + m.e,
      this.e * m.b + this.f * m.d + m.f
    );
  }

  applyX(x: number, y: number): number {
    return this.a * x + this.c * y + this.e;
  }

  applyY(x: number, y: number): number {
    return this.b * x + this.d * y + this.f;
  }

  /** 水平方向的缩放量（用于把线宽、字宽换算到目标坐标系） */
  scaleX(): number {
    return Math.sqrt(this.a * this.a + this.b * this.b);
  }

  /** 垂直方向的缩放量 */
  scaleY(): number {
    return Math.sqrt(this.c * this.c + this.d * this.d);
  }
}

/** 显示列表元素类型 */
export class PdfItemKind {
  static readonly TEXT: number = 0;
  static readonly PATH: number = 1;
  static readonly IMAGE: number = 2;
}

/** 显示列表元素基类 */
export abstract class PdfItem {
  /** 元素类型（ArkTS 里用 kind 判定比 instanceof 更省心） */
  readonly kind: number;

  constructor(kind: number) {
    this.kind = kind;
  }
}

/**
 * 一段文字。
 *
 * 位置是基线起点；每个字符的前进宽度由 advances 给出（单位与坐标相同），
 * 因此渲染端不需要自己测量字宽，就能和 PDF 里的排版严丝合缝。
 */
export class PdfTextItem extends PdfItem {
  /** 基线起点 x */
  x: number = 0;
  /** 基线 y */
  y: number = 0;
  /** 文本内容（已转成 Unicode） */
  text: string = '';
  /** 字号（点），已含文本矩阵与 CTM 的缩放 */
  sizePt: number = 12;
  /** 每个「完整字符」的前进宽度，长度与 text 的字符数一致 */
  advances: number[] = [];
  /** 顺时针旋转角度（度），横排文字为 0 */
  rotationDeg: number = 0;
  /** 颜色 0xRRGGBB */
  color: number = 0;
  bold: boolean = false;
  italic: boolean = false;
  /** 衬线体（Times 类），渲染端可据此选系统字体 */
  serif: boolean = false;
  monospace: boolean = false;

  constructor() {
    super(PdfItemKind.TEXT);
  }
}

/** 路径指令码 */
export class PdfPathOp {
  static readonly MOVE: number = 0;
  static readonly LINE: number = 1;
  static readonly CUBIC: number = 2;
  static readonly CLOSE: number = 3;
}

/**
 * 一条路径（矢量图形）。
 *
 * cmds 是扁平数组：`[MOVE, x, y, LINE, x, y, CUBIC, x1,y1,x2,y2,x3,y3, CLOSE, ...]`，
 * 坐标已变换到页面坐标系。扁平数组比嵌套对象省内存——一张矢量图可能有上万段。
 */
export class PdfPathItem extends PdfItem {
  cmds: number[] = [];
  /** 是否填充 */
  hasFill: boolean = false;
  fillColor: number = 0;
  /** 填充规则是否为奇偶（f* / B*） */
  evenOdd: boolean = false;
  /** 是否描边 */
  hasStroke: boolean = false;
  strokeColor: number = 0;
  /** 线宽（页面坐标，已含 CTM 缩放） */
  strokeWidth: number = 1;

  constructor() {
    super(PdfItemKind.PATH);
  }
}

/**
 * 一张图片。
 *
 * matrix 把「图像单位正方形」映射到页面坐标：(0,0) 是图像左下角、(1,1) 是右上角，
 * 也就是说 matrix 里通常 d < 0（因为页面坐标 y 向下）。
 * stream 直接持有图像 XObject（或内联图片合成出来的等价流），
 * 具体解码交给平台层，纯逻辑层不碰像素。
 */
export class PdfImageItem extends PdfItem {
  matrix: PdfMatrix = PdfMatrix.identity();
  /** 图像流对象 */
  stream: PdfObj = PdfObj.NULL_OBJ;
  /** 是否是 1 位蒙版（ImageMask），用当前填充色上色 */
  isMask: boolean = false;
  /** 蒙版颜色 0xRRGGBB */
  maskColor: number = 0;

  constructor() {
    super(PdfItemKind.IMAGE);
  }
}

/** 一页的显示列表 */
export class PdfDisplayList {
  /** 页面宽（pt，已含旋转） */
  widthPt: number = 612;
  /** 页面高（pt，已含旋转） */
  heightPt: number = 792;
  /** 按绘制顺序排列的元素 */
  items: PdfItem[] = [];
  /** 内容流里出现过但本项目不支持的编码（如 JBIG2），用于给用户提示 */
  warnings: string[] = [];

  /** 添加一条警告（去重） */
  warn(message: string): void {
    for (let i = 0; i < this.warnings.length; i++) {
      if (this.warnings[i] === message) {
        return;
      }
    }
    this.warnings.push(message);
  }
}

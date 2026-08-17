/**
 * 把 PDF 显示列表缩放到打印纸的可打印区。
 *
 * 显示列表的单位是点（pt）、原点在页左上、y 向下；
 * 打印页面的单位是像素。这里只做坐标换算，不解码图片——
 * 图片流仍挂在返回结构里，由平台层（PdfPrint）交给系统解码器。
 *
 * 缩放策略：整页等比放入可打印区并居中。这样 A4 的 PDF 打到 A4 纸上几乎 1:1，
 * 更大/更小的页面也不会被裁切。
 */

import { PdfDisplayList, PdfImageItem, PdfItemKind, PdfMatrix, PdfPathItem, PdfTextItem } from './PdfDisplayList';
import { PdfObj } from './PdfObject';

/** 缩放后的文字 */
export class LaidText {
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

/** 缩放后的路径 */
export class LaidPath {
  cmds: number[] = [];
  hasFill: boolean = false;
  fillColor: number = 0;
  evenOdd: boolean = false;
  hasStroke: boolean = false;
  strokeColor: number = 0;
  strokeWidth: number = 1;
}

/** 缩放后的图片（像素尚未解码） */
export class LaidImageRef {
  /** 目标矩形（轴对齐包围盒，给预览/裁剪用） */
  left: number = 0;
  top: number = 0;
  width: number = 0;
  height: number = 0;
  /** 把图像单位正方形映射到页面像素的矩阵 */
  matrix: PdfMatrix = PdfMatrix.identity();
  stream: PdfObj = PdfObj.NULL_OBJ;
  isMask: boolean = false;
  maskColor: number = 0;
}

export class LaidKind {
  static readonly TEXT: number = 0;
  static readonly PATH: number = 1;
  static readonly IMAGE: number = 2;
}

export class LaidItem {
  readonly kind: number;
  text: LaidText | null = null;
  path: LaidPath | null = null;
  image: LaidImageRef | null = null;

  constructor(kind: number) {
    this.kind = kind;
  }
}

/** 一页缩放到打印纸之后的内容 */
export class LaidPage {
  readonly widthPx: number;
  readonly heightPx: number;
  readonly items: LaidItem[] = [];
  readonly warnings: string[] = [];

  constructor(widthPx: number, heightPx: number) {
    this.widthPx = widthPx;
    this.heightPx = heightPx;
  }
}

export class PdfPageLayout {
  /**
   * 把一页显示列表缩放到可打印区。
   *
   * @param list PDF 页的显示列表（pt）
   * @param pageWidthPx 可打印区宽（像素）
   * @param pageHeightPx 可打印区高（像素）
   */
  static fit(list: PdfDisplayList, pageWidthPx: number, pageHeightPx: number): LaidPage {
    const out = new LaidPage(pageWidthPx, pageHeightPx);
    for (let i = 0; i < list.warnings.length; i++) {
      out.warnings.push(list.warnings[i]);
    }
    const srcW = Math.max(1, list.widthPt);
    const srcH = Math.max(1, list.heightPt);
    const scale = Math.min(pageWidthPx / srcW, pageHeightPx / srcH);
    const ox = (pageWidthPx - srcW * scale) / 2;
    const oy = (pageHeightPx - srcH * scale) / 2;

    for (let i = 0; i < list.items.length; i++) {
      const item = list.items[i];
      if (item.kind === PdfItemKind.TEXT) {
        const t = item as PdfTextItem;
        const laid = new LaidText();
        laid.x = ox + t.x * scale;
        laid.y = oy + t.y * scale;
        laid.text = t.text;
        laid.sizePx = t.sizePt * scale;
        laid.rotationDeg = t.rotationDeg;
        laid.color = t.color;
        laid.bold = t.bold;
        laid.italic = t.italic;
        laid.serif = t.serif;
        laid.monospace = t.monospace;
        for (let k = 0; k < t.advances.length; k++) {
          laid.advances.push(t.advances[k] * scale);
        }
        const op = new LaidItem(LaidKind.TEXT);
        op.text = laid;
        out.items.push(op);
      } else if (item.kind === PdfItemKind.PATH) {
        const p = item as PdfPathItem;
        const laid = new LaidPath();
        laid.cmds = PdfPageLayout.scaleCmds(p.cmds, scale, ox, oy);
        laid.hasFill = p.hasFill;
        laid.fillColor = p.fillColor;
        laid.evenOdd = p.evenOdd;
        laid.hasStroke = p.hasStroke;
        laid.strokeColor = p.strokeColor;
        laid.strokeWidth = Math.max(0.4, p.strokeWidth * scale);
        const op = new LaidItem(LaidKind.PATH);
        op.path = laid;
        out.items.push(op);
      } else if (item.kind === PdfItemKind.IMAGE) {
        const img = item as PdfImageItem;
        const m = img.matrix;
        const mapped = new PdfMatrix(m.a * scale, m.b * scale, m.c * scale, m.d * scale,
          ox + m.e * scale, oy + m.f * scale);
        const box = PdfPageLayout.unitBox(mapped);
        const ref = new LaidImageRef();
        ref.matrix = mapped;
        ref.left = box[0];
        ref.top = box[1];
        ref.width = box[2] - box[0];
        ref.height = box[3] - box[1];
        ref.stream = img.stream;
        ref.isMask = img.isMask;
        ref.maskColor = img.maskColor;
        const op = new LaidItem(LaidKind.IMAGE);
        op.image = ref;
        out.items.push(op);
      }
    }
    return out;
  }

  /** 缩放扁平路径指令里的坐标 */
  private static scaleCmds(cmds: number[], scale: number, ox: number, oy: number): number[] {
    const out: number[] = [];
    let i = 0;
    while (i < cmds.length) {
      const op = cmds[i];
      out.push(op);
      i++;
      let points = 0;
      if (op === 0 || op === 1) {
        points = 1;
      } else if (op === 2) {
        points = 3;
      }
      for (let k = 0; k < points; k++) {
        out.push(ox + cmds[i] * scale);
        out.push(oy + cmds[i + 1] * scale);
        i += 2;
      }
    }
    return out;
  }

  /** 单位正方形经矩阵变换后的轴对齐包围盒 [l, t, r, b] */
  private static unitBox(m: PdfMatrix): number[] {
    const xs: number[] = [m.applyX(0, 0), m.applyX(1, 0), m.applyX(1, 1), m.applyX(0, 1)];
    const ys: number[] = [m.applyY(0, 0), m.applyY(1, 0), m.applyY(1, 1), m.applyY(0, 1)];
    let minX = xs[0];
    let maxX = xs[0];
    let minY = ys[0];
    let maxY = ys[0];
    for (let i = 1; i < 4; i++) {
      minX = Math.min(minX, xs[i]);
      maxX = Math.max(maxX, xs[i]);
      minY = Math.min(minY, ys[i]);
      maxY = Math.max(maxY, ys[i]);
    }
    return [minX, minY, maxX, maxY];
  }
}

/**
 * .docx 富文本模型：Word 文档在排版之前的中间表示。
 *
 * 只保留「打印看得见」的信息：段落与字符格式、表格结构与边框、内嵌图片、页面设置。
 * 修订记录、批注、书签、域代码、页眉页脚等一律不进模型
 * （页眉页脚在 Word 里属于另一套部件，打印时通常也不是重点）。
 *
 * 长度单位统一换算成 **点（pt，1/72 英寸）**，因为 PDF 用的就是点：
 *  - Word 的缇（twip）= 1/20 pt；
 *  - 字号是半磅（half-point）；
 *  - 图片尺寸是 EMU（English Metric Unit）= 1/914400 英寸 = 1/12700 pt。
 */

/** 长度单位换算 */
export class DocxUnits {
  /** 缇 → 点 */
  static twipToPt(twip: number): number {
    return twip / 20;
  }

  /** 半磅 → 点 */
  static halfPointToPt(half: number): number {
    return half / 2;
  }

  /** EMU → 点 */
  static emuToPt(emu: number): number {
    return emu / 12700;
  }

  /** 八分之一磅（边框宽度单位）→ 点 */
  static eighthToPt(eighth: number): number {
    return eighth / 8;
  }
}

/** 水平对齐 */
export class DocxAlign {
  static readonly LEFT: number = 0;
  static readonly CENTER: number = 1;
  static readonly RIGHT: number = 2;
  static readonly JUSTIFY: number = 3;
}

/** 字符格式 */
export class DocxRunStyle {
  bold: boolean = false;
  italic: boolean = false;
  underline: boolean = false;
  strike: boolean = false;
  /** 字号（点） */
  sizePt: number = 10.5;
  /** 颜色 0xRRGGBB */
  color: number = 0;
  /** 衬线字体（宋体 / Times 一类） */
  serif: boolean = true;
  /** 等宽字体（Consolas / Courier 一类） */
  mono: boolean = false;
  /** 0 = 正常，1 = 上标，2 = 下标 */
  vertAlign: number = 0;
  /** 底纹/高亮颜色 0xRRGGBB，-1 表示无 */
  highlight: number = -1;

  clone(): DocxRunStyle {
    const s = new DocxRunStyle();
    s.bold = this.bold;
    s.italic = this.italic;
    s.underline = this.underline;
    s.strike = this.strike;
    s.sizePt = this.sizePt;
    s.color = this.color;
    s.serif = this.serif;
    s.mono = this.mono;
    s.vertAlign = this.vertAlign;
    s.highlight = this.highlight;
    return s;
  }
}

/** 段落格式 */
export class DocxParaStyle {
  align: number = DocxAlign.LEFT;
  /** 左缩进（点） */
  indentLeftPt: number = 0;
  /** 右缩进（点） */
  indentRightPt: number = 0;
  /** 首行缩进（点，负值表示悬挂缩进） */
  indentFirstPt: number = 0;
  /** 段前距（点） */
  spaceBeforePt: number = 0;
  /** 段后距（点） */
  spaceAfterPt: number = 0;
  /** 行距倍数（1 = 单倍行距） */
  lineMultiple: number = 1;
  /** 固定行距（点），> 0 时优先于倍数 */
  lineExactPt: number = 0;

  clone(): DocxParaStyle {
    const s = new DocxParaStyle();
    s.align = this.align;
    s.indentLeftPt = this.indentLeftPt;
    s.indentRightPt = this.indentRightPt;
    s.indentFirstPt = this.indentFirstPt;
    s.spaceBeforePt = this.spaceBeforePt;
    s.spaceAfterPt = this.spaceAfterPt;
    s.lineMultiple = this.lineMultiple;
    s.lineExactPt = this.lineExactPt;
    return s;
  }
}

/** 内嵌图片 */
export class DocxImage {
  /** 原始字节（JPEG / PNG / 其他） */
  data: Uint8Array = new Uint8Array(0);
  /** 显示宽度（点） */
  widthPt: number = 0;
  /** 显示高度（点） */
  heightPt: number = 0;
  /** 文件扩展名（小写，不含点） */
  ext: string = '';
}

/** 一段文字或一个特殊对象 */
export class DocxRun {
  static readonly BREAK_NONE: number = 0;
  static readonly BREAK_LINE: number = 1;
  static readonly BREAK_PAGE: number = 2;

  style: DocxRunStyle = new DocxRunStyle();
  /** 文本内容（制表符保留为 \t） */
  text: string = '';
  /** 图片，非 null 时 text 为空 */
  image: DocxImage | null = null;
  /** 换行/换页标记 */
  breakKind: number = DocxRun.BREAK_NONE;
}

/** 块级元素类型 */
export class DocxBlockKind {
  static readonly PARAGRAPH: number = 0;
  static readonly TABLE: number = 1;
}

/** 块级元素基类 */
export abstract class DocxBlock {
  readonly kind: number;

  constructor(kind: number) {
    this.kind = kind;
  }
}

/** 段落 */
export class DocxParagraph extends DocxBlock {
  style: DocxParaStyle = new DocxParaStyle();
  runs: DocxRun[] = [];
  /** 列表项前缀（如 `•`、`1.`），空串表示不是列表 */
  bullet: string = '';
  /** 列表项前缀所用的字符格式 */
  bulletStyle: DocxRunStyle = new DocxRunStyle();
  /** 大纲级别（0 = 正文，1~9 = 标题层级），影响分页时的孤行处理 */
  outlineLevel: number = 0;

  constructor() {
    super(DocxBlockKind.PARAGRAPH);
  }

  /** 段落是否完全没有内容（用于压缩空段落） */
  isEmpty(): boolean {
    for (let i = 0; i < this.runs.length; i++) {
      const run = this.runs[i];
      if (run.image !== null || run.breakKind !== DocxRun.BREAK_NONE || run.text.length > 0) {
        return false;
      }
    }
    return this.bullet.length === 0;
  }
}

/** 单元格四边边框（宽度为 0 表示无边框） */
export class DocxBorders {
  topPt: number = 0;
  bottomPt: number = 0;
  leftPt: number = 0;
  rightPt: number = 0;
  /** 边框颜色 0xRRGGBB */
  color: number = 0;

  clone(): DocxBorders {
    const b = new DocxBorders();
    b.topPt = this.topPt;
    b.bottomPt = this.bottomPt;
    b.leftPt = this.leftPt;
    b.rightPt = this.rightPt;
    b.color = this.color;
    return b;
  }
}

/** 表格单元格 */
export class DocxCell {
  /** 单元格内的块（通常是段落，也可能嵌套表格） */
  blocks: DocxBlock[] = [];
  /** 横向合并的列数 */
  gridSpan: number = 1;
  /** 是否是纵向合并的延续单元格（内容画在合并起始格里） */
  vMergeContinue: boolean = false;
  borders: DocxBorders = new DocxBorders();
  /** 底纹填充色 0xRRGGBB，-1 表示无 */
  fill: number = -1;
}

/** 表格行 */
export class DocxRow {
  cells: DocxCell[] = [];
  /** 指定行高（点），0 表示按内容 */
  heightPt: number = 0;
  /** 是否是重复表头行 */
  header: boolean = false;
}

/** 表格 */
export class DocxTable extends DocxBlock {
  rows: DocxRow[] = [];
  /** 各列宽度（点），来自 tblGrid */
  columnsPt: number[] = [];
  /** 单元格内边距（点） */
  cellPadPt: number = 3.6;

  constructor() {
    super(DocxBlockKind.TABLE);
  }
}

/** 页面设置 */
export class DocxSection {
  widthPt: number = 595.32;   // A4 纵向
  heightPt: number = 841.92;
  marginLeftPt: number = 90;
  marginRightPt: number = 90;
  marginTopPt: number = 72;
  marginBottomPt: number = 72;

  /** 正文可用宽度 */
  get contentWidthPt(): number {
    return Math.max(36, this.widthPt - this.marginLeftPt - this.marginRightPt);
  }

  /** 正文可用高度 */
  get contentHeightPt(): number {
    return Math.max(36, this.heightPt - this.marginTopPt - this.marginBottomPt);
  }
}

/** 解析出来的整篇文档 */
export class DocxDocument {
  blocks: DocxBlock[] = [];
  section: DocxSection = new DocxSection();
}

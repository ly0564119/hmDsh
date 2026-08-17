/**
 * PDF 内容流解释器：把页面的运算符流「执行」成显示列表。
 *
 * 覆盖打印真正用得到的运算符（PDF 32000-1 附录 A）：
 *  - 图形状态：q Q cm w gs
 *  - 路径构造与绘制：m l c v y h re / S s f F f* B B* b b* n / W W*
 *  - 颜色：CS cs SC SCN sc scn G g RG rg K k
 *  - 文本：BT ET Tf Td TD Tm T* TL Tc Tw Tz Ts Tr Tj TJ ' "
 *  - 外部对象：Do（图像 / Form 递归）、BI…ID…EI（内联图片）
 * 不支持但会安全跳过：着色 sh、图案填充（按中性灰）、Type3 字形过程、透明组。
 *
 * 关键点：
 *  - 文字位置严格按 PDF 的文本矩阵计算，每个字符的前进宽度取自字体度量，
 *    所以渲染端用系统字体也能保持原排版（见 PdfFont 的说明）；
 *  - 页面 /Rotate 与 CropBox 在「基础矩阵」里一次性吃掉，后续全是页面坐标；
 *  - 裁剪只按包围盒近似，用于剔除页面外的元素，不做真正的路径裁剪。
 */

import { PdfColorSpace } from './PdfColorSpace';
import { PdfDocument, PdfPageInfo } from './PdfDocument';
import {
  PdfDisplayList,
  PdfImageItem,
  PdfMatrix,
  PdfPathItem,
  PdfPathOp,
  PdfTextItem
} from './PdfDisplayList';
import { PdfFont } from './PdfFont';
import { PdfImageFilter } from './PdfFilters';
import { PdfLexer, PdfParser } from './PdfLexer';
import { PdfObj } from './PdfObject';
import { PdfStdFamily } from './PdfStdFonts';

/** 图形状态（q/Q 压栈的内容） */
class GState {
  ctm: PdfMatrix = PdfMatrix.identity();
  fillColor: number = 0;
  strokeColor: number = 0;
  fillSpace: PdfColorSpace = PdfColorSpace.deviceGray();
  strokeSpace: PdfColorSpace = PdfColorSpace.deviceGray();
  lineWidth: number = 1;
  /** 裁剪包围盒 [x0, y0, x1, y1]（页面坐标），null 表示不裁剪 */
  clip: number[] | null = null;
  /** 文本状态 */
  font: PdfFont | null = null;
  fontSize: number = 0;
  charSpacing: number = 0;
  wordSpacing: number = 0;
  /** 水平缩放（Tz/100） */
  hScale: number = 1;
  leading: number = 0;
  rise: number = 0;
  renderMode: number = 0;

  clone(): GState {
    const s = new GState();
    s.ctm = this.ctm.clone();
    s.fillColor = this.fillColor;
    s.strokeColor = this.strokeColor;
    s.fillSpace = this.fillSpace;
    s.strokeSpace = this.strokeSpace;
    s.lineWidth = this.lineWidth;
    s.clip = this.clip === null ? null : [this.clip[0], this.clip[1], this.clip[2], this.clip[3]];
    s.font = this.font;
    s.fontSize = this.fontSize;
    s.charSpacing = this.charSpacing;
    s.wordSpacing = this.wordSpacing;
    s.hScale = this.hScale;
    s.leading = this.leading;
    s.rise = this.rise;
    s.renderMode = this.renderMode;
    return s;
  }
}

export class PdfContentInterpreter {
  /** 单页最多产出的元素数，防止超复杂矢量图把内存/时间吃光 */
  private static readonly MAX_ITEMS: number = 120000;
  /** Form XObject 递归深度上限 */
  private static readonly MAX_DEPTH: number = 12;

  private readonly doc: PdfDocument;
  private readonly list: PdfDisplayList = new PdfDisplayList();
  /** 字体缓存：同一个字体字典在页面里会被 Tf 反复引用 */
  private readonly fontCache: Map<PdfObj, PdfFont> = new Map<PdfObj, PdfFont>();
  private gs: GState = new GState();
  private readonly stack: GState[] = [];
  /** 当前正在构造的路径（页面坐标） */
  private path: number[] = [];
  /** 路径起点，用于 h 闭合与 v/y 曲线 */
  private curX: number = 0;
  private curY: number = 0;
  private startX: number = 0;
  private startY: number = 0;
  /** 下一个绘制运算符后是否要把当前路径设为裁剪 */
  private pendingClip: number = 0; // 0 = 否，1 = 非零环绕，2 = 奇偶
  /** 文本矩阵与行首矩阵 */
  private tm: PdfMatrix = PdfMatrix.identity();
  private tlm: PdfMatrix = PdfMatrix.identity();
  /** 兜底字体 */
  private fallbackFont: PdfFont | null = null;

  private constructor(doc: PdfDocument) {
    this.doc = doc;
  }

  /**
   * 解释一页内容。
   * @returns 该页的显示列表（页面坐标，pt，y 向下）
   */
  static run(doc: PdfDocument, page: PdfPageInfo): PdfDisplayList {
    const interp = new PdfContentInterpreter(doc);
    interp.list.widthPt = page.widthPt;
    interp.list.heightPt = page.heightPt;
    interp.gs.ctm = PdfContentInterpreter.baseMatrix(page);
    const content = doc.pageContent(page);
    if (content.length === 0) {
      return interp.list;
    }
    interp.execute(content, page.resources, 0);
    return interp.list;
  }

  /**
   * 基础矩阵：PDF 用户空间（y 向上、原点在 CropBox 左下角）
   * → 页面坐标（y 向下、原点在页面左上角），并把 /Rotate 一并处理掉。
   *
   * 推导：把用户坐标先平移到框内，再按旋转角把「框」摆到显示方向。
   */
  static baseMatrix(page: PdfPageInfo): PdfMatrix {
    const llx = page.box[0];
    const lly = page.box[1];
    const urx = page.box[2];
    const ury = page.box[3];
    const rotate = page.rotate;
    if (rotate === 90) {
      // 顺时针 90°：用户 x 变成显示 y，用户 y 变成显示 x
      return new PdfMatrix(0, 1, 1, 0, -lly, -llx);
    }
    if (rotate === 180) {
      return new PdfMatrix(-1, 0, 0, 1, urx, -lly);
    }
    if (rotate === 270) {
      return new PdfMatrix(0, -1, -1, 0, ury, urx);
    }
    return new PdfMatrix(1, 0, 0, -1, -llx, ury);
  }

  /** 执行一段内容流 */
  private execute(content: Uint8Array, resources: PdfObj, depth: number): void {
    let parser = PdfParser.fromBytes(content, 0, content.length);
    const operands: PdfObj[] = [];
    let guard = 0;
    while (guard < 4000000) {
      guard++;
      const obj = parser.parseObject();
      if (obj === null) {
        break;
      }
      if (!obj.isKeyword()) {
        if (operands.length < 64) {
          operands.push(obj);
        }
        continue;
      }
      const op = obj.name;
      if (op === 'BI') {
        // 内联图片要按字节接管，读完后在新位置重建解析器
        const end = this.inlineImage(content, parser.position(), resources);
        parser = PdfParser.fromBytes(content, end, content.length);
        operands.length = 0;
        continue;
      }
      this.doOperator(op, operands, resources, depth);
      operands.length = 0;
      if (this.list.items.length > PdfContentInterpreter.MAX_ITEMS) {
        this.list.warn('页面内容过于复杂，部分图形已省略');
        break;
      }
    }
  }

  /** 取第 i 个操作数的数值（从后往前数更符合 PDF 习惯，这里直接按位置取） */
  private static numAt(operands: PdfObj[], i: number, fallback: number): number {
    if (i < 0 || i >= operands.length) {
      return fallback;
    }
    return operands[i].asNumber(fallback);
  }

  /** 分发运算符 */
  private doOperator(op: string, operands: PdfObj[], resources: PdfObj, depth: number): void {
    // 图形状态
    if (op === 'q') {
      this.stack.push(this.gs.clone());
      return;
    }
    if (op === 'Q') {
      const prev = this.stack.pop();
      if (prev !== undefined) {
        this.gs = prev;
      }
      return;
    }
    if (op === 'cm') {
      if (operands.length >= 6) {
        const m = new PdfMatrix(
          PdfContentInterpreter.numAt(operands, 0, 1), PdfContentInterpreter.numAt(operands, 1, 0),
          PdfContentInterpreter.numAt(operands, 2, 0), PdfContentInterpreter.numAt(operands, 3, 1),
          PdfContentInterpreter.numAt(operands, 4, 0), PdfContentInterpreter.numAt(operands, 5, 0));
        this.gs.ctm = m.multiply(this.gs.ctm);
      }
      return;
    }
    if (op === 'w') {
      this.gs.lineWidth = PdfContentInterpreter.numAt(operands, 0, 1);
      return;
    }
    if (op === 'gs') {
      this.applyExtGState(operands, resources);
      return;
    }

    // 路径构造
    if (op === 'm') {
      this.moveTo(PdfContentInterpreter.numAt(operands, 0, 0), PdfContentInterpreter.numAt(operands, 1, 0));
      return;
    }
    if (op === 'l') {
      this.lineTo(PdfContentInterpreter.numAt(operands, 0, 0), PdfContentInterpreter.numAt(operands, 1, 0));
      return;
    }
    if (op === 'c') {
      this.curveTo(
        PdfContentInterpreter.numAt(operands, 0, 0), PdfContentInterpreter.numAt(operands, 1, 0),
        PdfContentInterpreter.numAt(operands, 2, 0), PdfContentInterpreter.numAt(operands, 3, 0),
        PdfContentInterpreter.numAt(operands, 4, 0), PdfContentInterpreter.numAt(operands, 5, 0));
      return;
    }
    if (op === 'v') {
      // 第一个控制点等于当前点
      const x2 = PdfContentInterpreter.numAt(operands, 0, 0);
      const y2 = PdfContentInterpreter.numAt(operands, 1, 0);
      const x3 = PdfContentInterpreter.numAt(operands, 2, 0);
      const y3 = PdfContentInterpreter.numAt(operands, 3, 0);
      this.curveToDevice(this.curX, this.curY,
        this.gs.ctm.applyX(x2, y2), this.gs.ctm.applyY(x2, y2),
        this.gs.ctm.applyX(x3, y3), this.gs.ctm.applyY(x3, y3));
      return;
    }
    if (op === 'y') {
      // 第二个控制点等于终点
      const x1 = PdfContentInterpreter.numAt(operands, 0, 0);
      const y1 = PdfContentInterpreter.numAt(operands, 1, 0);
      const x3 = PdfContentInterpreter.numAt(operands, 2, 0);
      const y3 = PdfContentInterpreter.numAt(operands, 3, 0);
      const dx3 = this.gs.ctm.applyX(x3, y3);
      const dy3 = this.gs.ctm.applyY(x3, y3);
      this.curveToDevice(this.gs.ctm.applyX(x1, y1), this.gs.ctm.applyY(x1, y1), dx3, dy3, dx3, dy3);
      return;
    }
    if (op === 'h') {
      this.closePath();
      return;
    }
    if (op === 're') {
      this.appendRect(
        PdfContentInterpreter.numAt(operands, 0, 0), PdfContentInterpreter.numAt(operands, 1, 0),
        PdfContentInterpreter.numAt(operands, 2, 0), PdfContentInterpreter.numAt(operands, 3, 0));
      return;
    }

    // 路径绘制
    if (op === 'n') {
      this.endPath(false, false, false);
      return;
    }
    if (op === 'S') {
      this.endPath(false, true, false);
      return;
    }
    if (op === 's') {
      this.closePath();
      this.endPath(false, true, false);
      return;
    }
    if (op === 'f' || op === 'F') {
      this.endPath(true, false, false);
      return;
    }
    if (op === 'f*') {
      this.endPath(true, false, true);
      return;
    }
    if (op === 'B') {
      this.endPath(true, true, false);
      return;
    }
    if (op === 'B*') {
      this.endPath(true, true, true);
      return;
    }
    if (op === 'b') {
      this.closePath();
      this.endPath(true, true, false);
      return;
    }
    if (op === 'b*') {
      this.closePath();
      this.endPath(true, true, true);
      return;
    }
    if (op === 'W') {
      this.pendingClip = 1;
      return;
    }
    if (op === 'W*') {
      this.pendingClip = 2;
      return;
    }

    // 颜色
    if (op === 'g' || op === 'G') {
      const v = PdfContentInterpreter.numAt(operands, 0, 0);
      const color = PdfColorSpace.pack(v * 255, v * 255, v * 255);
      if (op === 'g') {
        this.gs.fillSpace = PdfColorSpace.deviceGray();
        this.gs.fillColor = color;
      } else {
        this.gs.strokeSpace = PdfColorSpace.deviceGray();
        this.gs.strokeColor = color;
      }
      return;
    }
    if (op === 'rg' || op === 'RG') {
      const color = PdfColorSpace.pack(
        PdfContentInterpreter.numAt(operands, 0, 0) * 255,
        PdfContentInterpreter.numAt(operands, 1, 0) * 255,
        PdfContentInterpreter.numAt(operands, 2, 0) * 255);
      if (op === 'rg') {
        this.gs.fillSpace = PdfColorSpace.deviceRgb();
        this.gs.fillColor = color;
      } else {
        this.gs.strokeSpace = PdfColorSpace.deviceRgb();
        this.gs.strokeColor = color;
      }
      return;
    }
    if (op === 'k' || op === 'K') {
      const values: number[] = [
        PdfContentInterpreter.numAt(operands, 0, 0), PdfContentInterpreter.numAt(operands, 1, 0),
        PdfContentInterpreter.numAt(operands, 2, 0), PdfContentInterpreter.numAt(operands, 3, 0)
      ];
      const cs = PdfColorSpace.deviceCmyk();
      const color = cs.toRgb(values);
      if (op === 'k') {
        this.gs.fillSpace = cs;
        this.gs.fillColor = color;
      } else {
        this.gs.strokeSpace = cs;
        this.gs.strokeColor = color;
      }
      return;
    }
    if (op === 'cs' || op === 'CS') {
      const space = operands.length > 0
        ? PdfColorSpace.parse(this.doc, operands[0], resources)
        : PdfColorSpace.deviceGray();
      if (op === 'cs') {
        this.gs.fillSpace = space;
        this.gs.fillColor = space.initialColor();
      } else {
        this.gs.strokeSpace = space;
        this.gs.strokeColor = space.initialColor();
      }
      return;
    }
    if (op === 'sc' || op === 'scn' || op === 'SC' || op === 'SCN') {
      const values: number[] = [];
      for (let i = 0; i < operands.length; i++) {
        if (operands[i].isNumber()) {
          values.push(operands[i].num);
        }
      }
      const isFill = op === 'sc' || op === 'scn';
      const space = isFill ? this.gs.fillSpace : this.gs.strokeSpace;
      let color = space.toRgb(values);
      if (values.length === 0) {
        // 只给了图案名（scn /P0）：按中性灰
        color = PdfColorSpace.pack(128, 128, 128);
      }
      if (isFill) {
        this.gs.fillColor = color;
      } else {
        this.gs.strokeColor = color;
      }
      return;
    }

    // 文本
    if (op === 'BT') {
      this.tm = PdfMatrix.identity();
      this.tlm = PdfMatrix.identity();
      return;
    }
    if (op === 'ET') {
      return;
    }
    if (op === 'Tf') {
      this.selectFont(operands, resources);
      return;
    }
    if (op === 'Td') {
      this.textNewLine(PdfContentInterpreter.numAt(operands, 0, 0),
        PdfContentInterpreter.numAt(operands, 1, 0));
      return;
    }
    if (op === 'TD') {
      const ty = PdfContentInterpreter.numAt(operands, 1, 0);
      this.gs.leading = -ty;
      this.textNewLine(PdfContentInterpreter.numAt(operands, 0, 0), ty);
      return;
    }
    if (op === 'Tm') {
      if (operands.length >= 6) {
        this.tlm = new PdfMatrix(
          PdfContentInterpreter.numAt(operands, 0, 1), PdfContentInterpreter.numAt(operands, 1, 0),
          PdfContentInterpreter.numAt(operands, 2, 0), PdfContentInterpreter.numAt(operands, 3, 1),
          PdfContentInterpreter.numAt(operands, 4, 0), PdfContentInterpreter.numAt(operands, 5, 0));
        this.tm = this.tlm.clone();
      }
      return;
    }
    if (op === 'T*') {
      this.textNewLine(0, -this.gs.leading);
      return;
    }
    if (op === 'TL') {
      this.gs.leading = PdfContentInterpreter.numAt(operands, 0, 0);
      return;
    }
    if (op === 'Tc') {
      this.gs.charSpacing = PdfContentInterpreter.numAt(operands, 0, 0);
      return;
    }
    if (op === 'Tw') {
      this.gs.wordSpacing = PdfContentInterpreter.numAt(operands, 0, 0);
      return;
    }
    if (op === 'Tz') {
      this.gs.hScale = PdfContentInterpreter.numAt(operands, 0, 100) / 100;
      return;
    }
    if (op === 'Ts') {
      this.gs.rise = PdfContentInterpreter.numAt(operands, 0, 0);
      return;
    }
    if (op === 'Tr') {
      this.gs.renderMode = Math.trunc(PdfContentInterpreter.numAt(operands, 0, 0));
      return;
    }
    if (op === 'Tj') {
      if (operands.length > 0 && operands[0].isString()) {
        this.showText(operands[0].asBytes());
      }
      return;
    }
    if (op === 'TJ') {
      if (operands.length > 0 && operands[0].isArray()) {
        this.showTextArray(operands[0].asArray());
      }
      return;
    }
    if (op === "'") {
      this.textNewLine(0, -this.gs.leading);
      if (operands.length > 0 && operands[0].isString()) {
        this.showText(operands[0].asBytes());
      }
      return;
    }
    if (op === '"') {
      // aw ac string "：先设字间距/词间距再换行显示
      this.gs.wordSpacing = PdfContentInterpreter.numAt(operands, 0, 0);
      this.gs.charSpacing = PdfContentInterpreter.numAt(operands, 1, 0);
      this.textNewLine(0, -this.gs.leading);
      if (operands.length > 2 && operands[2].isString()) {
        this.showText(operands[2].asBytes());
      }
      return;
    }

    // 外部对象
    if (op === 'Do') {
      if (operands.length > 0 && operands[0].isName()) {
        this.doXObject(operands[0].asName(), resources, depth);
      }
      return;
    }
    // sh / BMC / BDC / EMC / d / i / j / J / M / ri / d0 / d1 等：对打印结果无影响，忽略
  }

  /** /ExtGState：这里只关心它可能改的线宽与字体 */
  private applyExtGState(operands: PdfObj[], resources: PdfObj): void {
    if (operands.length === 0 || !operands[0].isName()) {
      return;
    }
    const dict = this.doc.dictGet(this.doc.dictGet(resources, 'ExtGState'), operands[0].asName());
    if (!dict.isDict()) {
      return;
    }
    const lw = this.doc.dictGet(dict, 'LW');
    if (lw.isNumber()) {
      this.gs.lineWidth = lw.num;
    }
    const fontArr = this.doc.dictGet(dict, 'Font').asArray();
    if (fontArr.length >= 2) {
      const fontDict = this.doc.resolve(fontArr[0]);
      if (fontDict.isDict()) {
        this.gs.font = this.loadFont(fontDict);
        this.gs.fontSize = this.doc.resolve(fontArr[1]).asNumber(this.gs.fontSize);
      }
    }
  }

  /** Tf：按资源名选字体 */
  private selectFont(operands: PdfObj[], resources: PdfObj): void {
    if (operands.length >= 2) {
      this.gs.fontSize = operands[1].asNumber(this.gs.fontSize);
    }
    if (operands.length === 0 || !operands[0].isName()) {
      return;
    }
    const fonts = this.doc.dictGet(resources, 'Font');
    const dict = this.doc.dictGet(fonts, operands[0].asName());
    if (dict.isDict()) {
      this.gs.font = this.loadFont(dict);
      return;
    }
    this.gs.font = this.fallback();
  }

  private fallback(): PdfFont {
    if (this.fallbackFont === null) {
      this.fallbackFont = PdfFont.standard();
    }
    return this.fallbackFont;
  }

  /** 带缓存地构建字体模型 */
  private loadFont(dict: PdfObj): PdfFont {
    const cached = this.fontCache.get(dict);
    if (cached !== undefined) {
      return cached;
    }
    let font: PdfFont;
    try {
      font = PdfFont.load(this.doc, dict);
    } catch (e) {
      font = this.fallback();
    }
    this.fontCache.set(dict, font);
    return font;
  }

  /** Td / TD / T* / ' / "：换行（相对行首矩阵平移） */
  private textNewLine(tx: number, ty: number): void {
    const m = new PdfMatrix(1, 0, 0, 1, tx, ty);
    this.tlm = m.multiply(this.tlm);
    this.tm = this.tlm.clone();
  }

  /** TJ：字符串与数字调整量交替 */
  private showTextArray(items: PdfObj[]): void {
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (item.isString()) {
        this.showText(item.asBytes());
      } else if (item.isNumber()) {
        // 数字是「以 1/1000 文本空间单位表示的负向移动量」
        const tx = -item.num / 1000 * this.gs.fontSize * this.gs.hScale;
        this.tm = new PdfMatrix(1, 0, 0, 1, tx, 0).multiply(this.tm);
      }
    }
  }

  /**
   * 显示一段文字。
   *
   * 逐字符计算前进宽度并推进文本矩阵；同一次调用内矩阵的旋转/缩放不变，
   * 因此可以合成为一个 PdfTextItem（起点 + 每字前进宽度）交给渲染端。
   */
  private showText(bytes: Uint8Array): void {
    const gs = this.gs;
    const font = gs.font === null ? this.fallback() : gs.font;
    if (bytes.length === 0) {
      return;
    }
    // 文本空间 → 页面坐标
    const m = this.tm.multiply(gs.ctm);
    const lx = Math.sqrt(m.a * m.a + m.b * m.b);
    const ly = Math.sqrt(m.c * m.c + m.d * m.d);
    const originX = m.applyX(0, gs.rise);
    const originY = m.applyY(0, gs.rise);
    // 渲染模式 3（不可见）与 7（仅裁剪）不画，但位置照样要推进（扫描版 PDF 的隐藏文字层）
    const invisible = gs.renderMode === 3 || gs.renderMode === 7;

    const item = new PdfTextItem();
    item.x = originX;
    item.y = originY;
    item.sizePt = gs.fontSize * ly;
    item.rotationDeg = Math.atan2(m.b, m.a) * 180 / Math.PI;
    item.color = gs.renderMode === 1 || gs.renderMode === 5 ? gs.strokeColor : gs.fillColor;
    item.bold = font.bold;
    item.italic = font.italic;
    item.serif = font.family === PdfStdFamily.TIMES;
    item.monospace = font.monospace;
    let text = '';
    const advances: number[] = [];

    let totalTx = 0;
    let i = 0;
    while (i < bytes.length) {
      const len = font.codeLengthAt(bytes, i);
      const code = PdfFont.codeAt(bytes, i, len);
      i += len;
      const w0 = font.widthOf(code) / 1000;
      let tx = (w0 * gs.fontSize + gs.charSpacing) * gs.hScale;
      if (font.isWordSpaceCode(code, len)) {
        tx += gs.wordSpacing * gs.hScale;
      }
      const deviceAdvance = tx * lx;
      if (!invisible) {
        const glyphText = PdfContentInterpreter.printable(font.textOf(code));
        if (glyphText.length > 0) {
          // 一个码可能映射到多个字符（连字/代理对），把前进宽度平摊
          const chars = PdfContentInterpreter.splitChars(glyphText);
          const share = chars.length > 0 ? deviceAdvance / chars.length : deviceAdvance;
          for (let k = 0; k < chars.length; k++) {
            text += chars[k];
            advances.push(share);
          }
        } else if (text.length > 0) {
          // 不可显示字符：把宽度并入上一个字符，保持后续位置正确
          advances[advances.length - 1] = advances[advances.length - 1] + deviceAdvance;
        } else {
          item.x += deviceAdvance * Math.cos(item.rotationDeg * Math.PI / 180);
          item.y += deviceAdvance * Math.sin(item.rotationDeg * Math.PI / 180);
        }
      }
      totalTx += tx;
    }
    // 推进文本矩阵
    this.tm = new PdfMatrix(1, 0, 0, 1, totalTx, 0).multiply(this.tm);

    if (invisible || text.length === 0 || item.sizePt <= 0) {
      return;
    }
    if (!this.visible(item.x, item.y - item.sizePt, item.x + totalTx * lx, item.y + item.sizePt * 0.3)) {
      return;
    }
    item.text = text;
    item.advances = advances;
    this.list.items.push(item);
  }

  /** 去掉控制字符（换行、制表符等在 PDF 文本里没有换行语义） */
  private static printable(text: string): string {
    let out = '';
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if (c === 0x0a || c === 0x0d || c === 0x09 || c === 0) {
        continue;
      }
      out += text.charAt(i);
    }
    return out;
  }

  /** 按「完整字符」切分（代理对算一个） */
  private static splitChars(text: string): string[] {
    const out: string[] = [];
    let i = 0;
    while (i < text.length) {
      const c = text.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
        out.push(text.substring(i, i + 2));
        i += 2;
        continue;
      }
      out.push(text.charAt(i));
      i++;
    }
    return out;
  }

  /** 元素包围盒是否与裁剪区、页面有交集 */
  private visible(x0: number, y0: number, x1: number, y1: number): boolean {
    const minX = Math.min(x0, x1);
    const maxX = Math.max(x0, x1);
    const minY = Math.min(y0, y1);
    const maxY = Math.max(y0, y1);
    // 页面外（留 4pt 余量，避免边界元素被误删）
    if (maxX < -4 || minX > this.list.widthPt + 4 || maxY < -4 || minY > this.list.heightPt + 4) {
      return false;
    }
    const clip = this.gs.clip;
    if (clip === null) {
      return true;
    }
    return !(maxX < clip[0] - 0.5 || minX > clip[2] + 0.5 || maxY < clip[1] - 0.5 || minY > clip[3] + 0.5);
  }

  private moveTo(x: number, y: number): void {
    this.curX = this.gs.ctm.applyX(x, y);
    this.curY = this.gs.ctm.applyY(x, y);
    this.startX = this.curX;
    this.startY = this.curY;
    this.path.push(PdfPathOp.MOVE, this.curX, this.curY);
  }

  private lineTo(x: number, y: number): void {
    this.curX = this.gs.ctm.applyX(x, y);
    this.curY = this.gs.ctm.applyY(x, y);
    this.path.push(PdfPathOp.LINE, this.curX, this.curY);
  }

  private curveTo(x1: number, y1: number, x2: number, y2: number, x3: number, y3: number): void {
    const m = this.gs.ctm;
    this.curveToDevice(m.applyX(x1, y1), m.applyY(x1, y1), m.applyX(x2, y2), m.applyY(x2, y2),
      m.applyX(x3, y3), m.applyY(x3, y3));
  }

  /** 已变换到页面坐标的三次贝塞尔 */
  private curveToDevice(x1: number, y1: number, x2: number, y2: number,
    x3: number, y3: number): void {
    if (this.path.length === 0) {
      this.path.push(PdfPathOp.MOVE, x1, y1);
      this.startX = x1;
      this.startY = y1;
    }
    this.path.push(PdfPathOp.CUBIC, x1, y1, x2, y2, x3, y3);
    this.curX = x3;
    this.curY = y3;
  }

  private closePath(): void {
    if (this.path.length > 0) {
      this.path.push(PdfPathOp.CLOSE);
      this.curX = this.startX;
      this.curY = this.startY;
    }
  }

  /** re：矩形（按 PDF 语义是一个闭合子路径） */
  private appendRect(x: number, y: number, w: number, h: number): void {
    const m = this.gs.ctm;
    const x0 = m.applyX(x, y);
    const y0 = m.applyY(x, y);
    const x1 = m.applyX(x + w, y);
    const y1 = m.applyY(x + w, y);
    const x2 = m.applyX(x + w, y + h);
    const y2 = m.applyY(x + w, y + h);
    const x3 = m.applyX(x, y + h);
    const y3 = m.applyY(x, y + h);
    this.path.push(PdfPathOp.MOVE, x0, y0, PdfPathOp.LINE, x1, y1,
      PdfPathOp.LINE, x2, y2, PdfPathOp.LINE, x3, y3, PdfPathOp.CLOSE);
    this.curX = x0;
    this.curY = y0;
    this.startX = x0;
    this.startY = y0;
  }

  /**
   * 结束当前路径：按需要生成填充/描边元素，并处理挂起的裁剪。
   * 裁剪只取路径包围盒（近似），够用来剔除页面外与被裁掉的内容。
   */
  private endPath(fill: boolean, stroke: boolean, evenOdd: boolean): void {
    const path = this.path;
    this.path = [];
    if (path.length === 0) {
      this.pendingClip = 0;
      return;
    }
    if (this.pendingClip !== 0) {
      const box = PdfContentInterpreter.pathBounds(path);
      if (box !== null) {
        const clip = this.gs.clip;
        if (clip === null) {
          this.gs.clip = box;
        } else {
          this.gs.clip = [
            Math.max(clip[0], box[0]), Math.max(clip[1], box[1]),
            Math.min(clip[2], box[2]), Math.min(clip[3], box[3])
          ];
        }
      }
      this.pendingClip = 0;
    }
    if (!fill && !stroke) {
      return;
    }
    const box = PdfContentInterpreter.pathBounds(path);
    if (box === null) {
      return;
    }
    const strokeWidth = Math.max(this.gs.lineWidth * this.gs.ctm.scaleX(), 0.1);
    if (!this.visible(box[0] - strokeWidth, box[1] - strokeWidth,
      box[2] + strokeWidth, box[3] + strokeWidth)) {
      return;
    }
    const item = new PdfPathItem();
    item.cmds = path;
    item.hasFill = fill;
    item.fillColor = this.gs.fillColor;
    item.evenOdd = evenOdd;
    item.hasStroke = stroke;
    item.strokeColor = this.gs.strokeColor;
    item.strokeWidth = strokeWidth;
    this.list.items.push(item);
  }

  /** 路径包围盒（对贝塞尔取控制点包围盒，略大但足够用于裁剪判断） */
  private static pathBounds(cmds: number[]): number[] | null {
    let minX = Number.MAX_VALUE;
    let minY = Number.MAX_VALUE;
    let maxX = -Number.MAX_VALUE;
    let maxY = -Number.MAX_VALUE;
    let i = 0;
    let count = 0;
    while (i < cmds.length) {
      const op = cmds[i];
      let points = 0;
      if (op === PdfPathOp.MOVE || op === PdfPathOp.LINE) {
        points = 1;
      } else if (op === PdfPathOp.CUBIC) {
        points = 3;
      }
      i++;
      for (let k = 0; k < points; k++) {
        const x = cmds[i];
        const y = cmds[i + 1];
        i += 2;
        count++;
        if (x < minX) {
          minX = x;
        }
        if (x > maxX) {
          maxX = x;
        }
        if (y < minY) {
          minY = y;
        }
        if (y > maxY) {
          maxY = y;
        }
      }
    }
    if (count === 0) {
      return null;
    }
    return [minX, minY, maxX, maxY];
  }

  /** Do：图像或 Form */
  private doXObject(name: string, resources: PdfObj, depth: number): void {
    const xobjects = this.doc.dictGet(resources, 'XObject');
    const obj = this.doc.dictGet(xobjects, name);
    if (!obj.isStream()) {
      return;
    }
    const subtype = this.doc.dictGet(obj, 'Subtype').asName();
    if (subtype === 'Image') {
      this.drawImage(obj);
      return;
    }
    if (subtype !== 'Form' && !obj.has('BBox')) {
      return;
    }
    if (depth >= PdfContentInterpreter.MAX_DEPTH) {
      return;
    }
    // Form XObject：保存状态 → 叠加 /Matrix 与 /BBox 裁剪 → 用它自己的资源执行。
    // Form 内部的 q/Q 可能不配对，所以记下栈深度，执行完强制恢复。
    const saved = this.gs;
    const savedStackDepth = this.stack.length;
    this.gs = saved.clone();
    const matrixArr = this.doc.dictGet(obj, 'Matrix').asArray();
    if (matrixArr.length >= 6) {
      const m = new PdfMatrix(
        this.doc.resolve(matrixArr[0]).asNumber(1), this.doc.resolve(matrixArr[1]).asNumber(0),
        this.doc.resolve(matrixArr[2]).asNumber(0), this.doc.resolve(matrixArr[3]).asNumber(1),
        this.doc.resolve(matrixArr[4]).asNumber(0), this.doc.resolve(matrixArr[5]).asNumber(0));
      this.gs.ctm = m.multiply(this.gs.ctm);
    }
    const bbox = this.doc.rectOf(obj, 'BBox');
    if (bbox !== null) {
      const corners = PdfContentInterpreter.transformBox(bbox, this.gs.ctm);
      const clip = this.gs.clip;
      this.gs.clip = clip === null ? corners : [
        Math.max(clip[0], corners[0]), Math.max(clip[1], corners[1]),
        Math.min(clip[2], corners[2]), Math.min(clip[3], corners[3])
      ];
    }
    let formRes = this.doc.dictGet(obj, 'Resources');
    if (!formRes.isDict()) {
      formRes = resources;
    }
    const savedPath = this.path;
    const savedTm = this.tm;
    const savedTlm = this.tlm;
    this.path = [];
    this.execute(this.doc.getStreamData(obj), formRes, depth + 1);
    this.path = savedPath;
    this.tm = savedTm;
    this.tlm = savedTlm;
    while (this.stack.length > savedStackDepth) {
      this.stack.pop();
    }
    this.gs = saved;
  }

  /** 把用户空间矩形按矩阵变换后取包围盒 */
  private static transformBox(box: number[], m: PdfMatrix): number[] {
    const xs: number[] = [
      m.applyX(box[0], box[1]), m.applyX(box[2], box[1]),
      m.applyX(box[2], box[3]), m.applyX(box[0], box[3])
    ];
    const ys: number[] = [
      m.applyY(box[0], box[1]), m.applyY(box[2], box[1]),
      m.applyY(box[2], box[3]), m.applyY(box[0], box[3])
    ];
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

  /** 生成图像元素 */
  private drawImage(stream: PdfObj): void {
    const m = this.gs.ctm;
    // 单位正方形的四角变换后取包围盒，判断是否在可见区域内
    const box = PdfContentInterpreter.transformBox([0, 0, 1, 1], m);
    if (!this.visible(box[0], box[1], box[2], box[3])) {
      return;
    }
    const width = Math.abs(box[2] - box[0]);
    const height = Math.abs(box[3] - box[1]);
    if (width < 0.05 || height < 0.05) {
      return; // 退化成线的图片（有些文档用它藏东西）直接跳过
    }
    const filter = this.doc.decodeImageStream(stream).imageFilter;
    if (filter === PdfImageFilter.JBIG2) {
      this.list.warn('文档里有 JBIG2 压缩的图像，暂不支持，已跳过');
      return;
    }
    if (filter === PdfImageFilter.JPX) {
      this.list.warn('文档里有 JPEG2000 图像，可能无法显示');
    }
    const item = new PdfImageItem();
    item.matrix = m.clone();
    item.stream = stream;
    item.isMask = this.doc.dictGet(stream, 'ImageMask').asBool(false);
    item.maskColor = this.gs.fillColor;
    this.list.items.push(item);
  }

  /**
   * 内联图片：`BI <键值对> ID <二进制数据> EI`。
   *
   * 键名是缩写（W/H/BPC/CS/F/DP/IM/D），这里统一展开成标准键，
   * 之后就能和普通图像 XObject 走同一条解码路径。
   *
   * @param start `BI` 之后的位置
   * @returns `EI` 之后的位置
   */
  private inlineImage(content: Uint8Array, start: number, resources: PdfObj): number {
    const parser = PdfParser.fromBytes(content, start, content.length);
    const map = new Map<string, PdfObj>();
    let guard = 0;
    while (guard < 64) {
      guard++;
      const key = parser.parseObject();
      if (key === null) {
        return content.length;
      }
      if (key.isKeyword()) {
        if (key.name === 'ID') {
          break;
        }
        continue;
      }
      if (!key.isName()) {
        continue;
      }
      const value = parser.parseObject();
      if (value === null) {
        return content.length;
      }
      if (value.isKeyword() && value.name === 'ID') {
        break;
      }
      map.set(PdfContentInterpreter.expandInlineKey(key.asName()), value);
    }
    // ID 之后紧跟一个空白字节，然后是数据
    let dataStart = parser.position();
    if (dataStart < content.length && PdfLexer.isWhite(content[dataStart])) {
      dataStart++;
    }
    const dict = PdfObj.ofDict(map);
    const dataEnd = this.findInlineImageEnd(content, dataStart, dict);
    const raw = content.subarray(dataStart, dataEnd);
    const stream = PdfObj.ofStream(map, raw);

    // 画出来（内联图片没有 /Subtype，直接按图像处理）
    const m = this.gs.ctm;
    const box = PdfContentInterpreter.transformBox([0, 0, 1, 1], m);
    if (this.visible(box[0], box[1], box[2], box[3])) {
      const item = new PdfImageItem();
      item.matrix = m.clone();
      item.stream = stream;
      item.isMask = this.doc.dictGet(stream, 'ImageMask').asBool(false);
      item.maskColor = this.gs.fillColor;
      // 内联图片的颜色空间名可能引用资源字典（/CS /CS0），先解引用成对象存回去
      const cs = stream.get('ColorSpace');
      if (cs.isName()) {
        const named = this.doc.dictGet(this.doc.dictGet(resources, 'ColorSpace'), cs.asName());
        if (!named.isNull()) {
          stream.set('ColorSpace', named);
        }
      }
      this.list.items.push(item);
    }

    // 跳过 EI
    let p = dataEnd;
    while (p + 1 < content.length) {
      if (content[p] === 0x45 && content[p + 1] === 0x49) {
        return p + 2;
      }
      p++;
    }
    return content.length;
  }

  /** 内联图片的缩写键 → 标准键 */
  private static expandInlineKey(key: string): string {
    if (key === 'W') {
      return 'Width';
    }
    if (key === 'H') {
      return 'Height';
    }
    if (key === 'BPC') {
      return 'BitsPerComponent';
    }
    if (key === 'CS') {
      return 'ColorSpace';
    }
    if (key === 'F') {
      return 'Filter';
    }
    if (key === 'DP') {
      return 'DecodeParms';
    }
    if (key === 'IM') {
      return 'ImageMask';
    }
    if (key === 'D') {
      return 'Decode';
    }
    if (key === 'I') {
      return 'Interpolate';
    }
    if (key === 'L') {
      return 'Length';
    }
    return key;
  }

  /**
   * 找内联图片数据的结束位置。
   *
   * 优先用 /L（有些生成器会写）；否则若没有过滤器就按 宽×高×分量 算出准确长度；
   * 都不行才扫描「空白 + EI + 分隔符」——这是最后手段，因为二进制数据里可能出现 "EI"。
   */
  private findInlineImageEnd(content: Uint8Array, dataStart: number, dict: PdfObj): number {
    const declared = this.doc.numberOf(dict, 'Length', -1);
    if (declared > 0 && dataStart + declared <= content.length) {
      return dataStart + Math.trunc(declared);
    }
    const filter = dict.get('Filter');
    const hasFilter = filter.isName() || (filter.isArray() && filter.asArray().length > 0);
    if (!hasFilter) {
      const width = Math.trunc(this.doc.numberOf(dict, 'Width', 0));
      const height = Math.trunc(this.doc.numberOf(dict, 'Height', 0));
      const bpc = dict.get('ImageMask').asBool(false)
        ? 1 : Math.trunc(this.doc.numberOf(dict, 'BitsPerComponent', 8));
      let comps = 1;
      const cs = dict.get('ColorSpace');
      if (cs.isName()) {
        const name = cs.asName();
        if (name === 'DeviceRGB' || name === 'RGB' || name === 'CalRGB') {
          comps = 3;
        } else if (name === 'DeviceCMYK' || name === 'CMYK') {
          comps = 4;
        }
      }
      if (width > 0 && height > 0) {
        const rowBytes = Math.ceil(width * comps * bpc / 8);
        const total = rowBytes * height;
        if (dataStart + total <= content.length) {
          return dataStart + total;
        }
      }
    }
    for (let p = dataStart + 1; p + 2 < content.length; p++) {
      if (content[p] === 0x45 && content[p + 1] === 0x49 &&
        PdfLexer.isWhite(content[p - 1]) &&
        (p + 2 >= content.length || PdfLexer.isWhite(content[p + 2]))) {
        return p - 1; // 去掉 EI 前的那个空白
      }
    }
    return content.length;
  }
}

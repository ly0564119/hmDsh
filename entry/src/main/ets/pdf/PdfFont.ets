/**
 * PDF 字体模型：把字体字典变成「字节流 → 一串（字符宽度 + Unicode 文本）」的能力。
 *
 * 打印时我们不解析内嵌字体的轮廓（那需要完整的 TrueType/CFF 解释器），
 * 而是取出每个字符的 **Unicode** 和 **PDF 声明的前进宽度**，
 * 再用系统字体按 PDF 给的位置逐字绘制。这样：
 *  - 位置、行距、分栏、对齐完全按 PDF 来（宽度用的是 PDF 自己的度量）；
 *  - 字形形状用系统字体替代（中文能正常显示，不会变成方框）。
 *
 * 需要处理的三类字体：
 *  1. 简单字体（Type1 / TrueType / Type3）：单字节编码，Widths[FirstChar..LastChar]；
 *  2. 复合字体（Type0）：CMap 决定字节数与 CID，宽度来自 DescendantFonts 的 W / DW；
 *  3. 标准 14 字体：没有 Widths 时用 AFM 官方度量兜底。
 */

import { PdfDocument } from './PdfDocument';
import { PdfLexer } from './PdfLexer';
import { PdfKind, PdfObj } from './PdfObject';
import { PdfStdFamily, PdfStdFonts } from './PdfStdFonts';

/** CMap 里的一段码位区间，用于确定「一个码占几个字节」 */
class CodespaceRange {
  bytes: number = 1;
  low: number = 0;
  high: number = 0;
}

/** CID 区间映射：[low, high] 的码依次映射到 cid, cid+1, ... */
class CidRange {
  low: number = 0;
  high: number = 0;
  cid: number = 0;
}

/**
 * CMap：码位 → CID，以及码位的字节长度规则。
 * ToUnicode 也是同一套 CMap 语法，但映射目标是文本，所以单独放在 PdfFont 里。
 */
class PdfCMap {
  /** 码位区间（按字节数分组） */
  ranges: CodespaceRange[] = [];
  /** 单码映射 */
  single: Map<number, number> = new Map<number, number>();
  /** 区间映射 */
  cidRanges: CidRange[] = [];
  /** 是否是 Identity（码位直接当 CID，最常见） */
  identity: boolean = false;
  /** 是否是「码位本身就是 Unicode」的 CMap（UniGB-UCS2-H 之类） */
  unicodeCodes: boolean = false;
  /** 未声明 codespace 时的默认字节数 */
  defaultBytes: number = 2;

  /** 某个位置的码占几个字节 */
  bytesAt(data: Uint8Array, i: number): number {
    if (this.ranges.length === 0) {
      return this.defaultBytes;
    }
    // 按字节数从少到多试，落在某个区间就用它
    for (let n = 1; n <= 4; n++) {
      if (i + n > data.length) {
        break;
      }
      let code = 0;
      for (let k = 0; k < n; k++) {
        code = code * 256 + data[i + k];
      }
      for (let r = 0; r < this.ranges.length; r++) {
        const range = this.ranges[r];
        if (range.bytes === n && code >= range.low && code <= range.high) {
          return n;
        }
      }
    }
    return this.defaultBytes;
  }

  /** 码位 → CID */
  cidOf(code: number): number {
    if (this.identity) {
      return code;
    }
    const s = this.single.get(code);
    if (s !== undefined) {
      return s;
    }
    for (let i = 0; i < this.cidRanges.length; i++) {
      const r = this.cidRanges[i];
      if (code >= r.low && code <= r.high) {
        return r.cid + (code - r.low);
      }
    }
    return code;
  }
}

export class PdfFont {
  /** 是否复合字体（Type0） */
  isComposite: boolean = false;
  /** 字体名（去掉子集前缀） */
  baseFont: string = '';
  /** 标准字体族（决定兜底字宽表与渲染时用衬线体还是黑体） */
  family: number = PdfStdFamily.HELVETICA;
  bold: boolean = false;
  italic: boolean = false;
  /** 等宽字体（表格/代码常用，渲染时可提示用等宽系统字体） */
  monospace: boolean = false;
  /** Type3 字体：宽度要经 FontMatrix 换算 */
  private isType3: boolean = false;
  /** Type3 的 FontMatrix[0]，用于把字形空间宽度换算成 1/1000 em */
  private type3Scale: number = 0.001;

  /** 简单字体：码位 → 字形名 */
  private glyphNames: string[] | null = null;
  /** 简单字体：码位 → 宽度（1/1000 em），-1 表示未声明 */
  private simpleWidths: Float64Array | null = null;
  /** 复合字体：CID → 宽度 */
  private cidWidths: Map<number, number> = new Map<number, number>();
  /** 复合字体默认宽度 */
  private defaultWidth: number = 1000;
  /** 字体描述符里的 MissingWidth */
  private missingWidth: number = -1;
  /** 编码 CMap（仅复合字体） */
  private cmap: PdfCMap | null = null;
  /** ToUnicode：码位 → 文本 */
  private toUnicode: Map<number, string> | null = null;
  /** 宽度查询缓存（同一个码会被反复问到） */
  private widthCache: Map<number, number> = new Map<number, number>();

  /**
   * 从字体字典构建字体模型。
   * @param doc 所属文档（要用它解引用与读流）
   * @param dict 字体字典
   */
  static load(doc: PdfDocument, dict: PdfObj): PdfFont {
    const font = new PdfFont();
    const subtype = doc.dictGet(dict, 'Subtype').asName();
    const baseFontRaw = doc.dictGet(dict, 'BaseFont').asName();
    font.baseFont = PdfStdFonts.normalizeBaseFont(baseFontRaw);
    font.isComposite = subtype === 'Type0';
    font.isType3 = subtype === 'Type3';

    if (font.isComposite) {
      font.loadComposite(doc, dict);
    } else {
      font.loadSimple(doc, dict);
    }
    font.loadToUnicode(doc, dict);
    return font;
  }

  /**
   * 兜底字体：内容流里 Tf 指向的字体资源缺失时用它，
   * 保证文字还能按 Helvetica 的度量画出来（总比整段文字消失好）。
   */
  static standard(): PdfFont {
    const font = new PdfFont();
    font.baseFont = 'Helvetica';
    font.family = PdfStdFamily.HELVETICA;
    const table = PdfStdFonts.encoding('WinAnsiEncoding');
    const names: string[] = [];
    for (let i = 0; i < 256; i++) {
      names.push(table[i]);
    }
    font.glyphNames = names;
    return font;
  }

  /** 读 FontDescriptor 里的样式信息（比名字更可靠） */
  private applyDescriptor(doc: PdfDocument, descriptor: PdfObj): void {
    if (!descriptor.isDict()) {
      return;
    }
    const flags = Math.trunc(doc.numberOf(descriptor, 'Flags', 0));
    if ((flags & 1) !== 0) {
      this.monospace = true;
    }
    if ((flags & 2) !== 0 && this.family !== PdfStdFamily.COURIER) {
      this.family = PdfStdFamily.TIMES; // Serif 标志位
    }
    if ((flags & 64) === 0 && (flags & 4) !== 0) {
      // 符号字体（非标准编码），保留族判断即可
    }
    if ((flags & 0x40000) !== 0) {
      this.bold = true; // ForceBold
    }
    const italicAngle = doc.numberOf(descriptor, 'ItalicAngle', 0);
    if (italicAngle !== 0) {
      this.italic = true;
    }
    const weight = doc.numberOf(descriptor, 'FontWeight', 0);
    if (weight >= 600) {
      this.bold = true;
    }
    const stemV = doc.numberOf(descriptor, 'StemV', 0);
    if (stemV >= 120) {
      this.bold = true;
    }
    const mw = doc.numberOf(descriptor, 'MissingWidth', -1);
    if (mw >= 0) {
      this.missingWidth = mw;
    }
  }

  /** 简单字体：编码表 + Widths */
  private loadSimple(doc: PdfDocument, dict: PdfObj): void {
    this.family = PdfStdFonts.familyOf(this.baseFont);
    this.bold = PdfStdFonts.boldByName(this.baseFont);
    this.italic = PdfStdFonts.italicByName(this.baseFont);
    this.monospace = this.family === PdfStdFamily.COURIER;
    this.applyDescriptor(doc, doc.dictGet(dict, 'FontDescriptor'));

    // 基础编码：显式指定优先，其次按字体内置编码
    let baseEncName = PdfStdFonts.builtinEncodingName(this.family);
    const encoding = doc.dictGet(dict, 'Encoding');
    let differences: PdfObj[] = [];
    if (encoding.isName()) {
      baseEncName = encoding.asName();
    } else if (encoding.isDict()) {
      const base = doc.dictGet(encoding, 'BaseEncoding').asName();
      if (base.length > 0) {
        baseEncName = base;
      }
      differences = doc.dictGet(encoding, 'Differences').asArray();
    }
    const table = PdfStdFonts.encoding(baseEncName);
    const names: string[] = [];
    for (let i = 0; i < 256; i++) {
      names.push(table[i]);
    }
    // Differences：`[起始码 /名字 /名字 ... 另一个起始码 /名字 ...]`
    let code = 0;
    for (let i = 0; i < differences.length; i++) {
      const item = doc.resolve(differences[i]);
      if (item.isNumber()) {
        code = item.asInt(0);
      } else if (item.isName()) {
        if (code >= 0 && code < 256) {
          names[code] = item.asName();
        }
        code++;
      }
    }
    this.glyphNames = names;

    if (this.isType3) {
      // Type3 的宽度在字形空间，要乘 FontMatrix 的 a 分量再放大到 1/1000
      const matrix = doc.dictGet(dict, 'FontMatrix').asArray();
      if (matrix.length >= 4) {
        const a = doc.resolve(matrix[0]).asNumber(0.001);
        if (a !== 0) {
          this.type3Scale = a;
        }
      }
    }

    const widths = doc.dictGet(dict, 'Widths').asArray();
    if (widths.length > 0) {
      const first = Math.trunc(doc.numberOf(dict, 'FirstChar', 0));
      const arr = new Float64Array(256);
      for (let i = 0; i < 256; i++) {
        arr[i] = -1;
      }
      for (let i = 0; i < widths.length; i++) {
        const target = first + i;
        if (target < 0 || target > 255) {
          continue;
        }
        let w = doc.resolve(widths[i]).asNumber(-1);
        if (w < 0) {
          continue;
        }
        if (this.isType3) {
          w = w * this.type3Scale * 1000;
        }
        arr[target] = w;
      }
      this.simpleWidths = arr;
    }
  }

  /** 复合字体（Type0）：CMap + DescendantFonts */
  private loadComposite(doc: PdfDocument, dict: PdfObj): void {
    const descendants = doc.dictGet(dict, 'DescendantFonts').asArray();
    let cidFont: PdfObj = PdfObj.NULL_OBJ;
    if (descendants.length > 0) {
      cidFont = doc.resolve(descendants[0]);
    }
    if (cidFont.isDict()) {
      const cidBase = doc.dictGet(cidFont, 'BaseFont').asName();
      if (cidBase.length > 0 && this.baseFont.length === 0) {
        this.baseFont = PdfStdFonts.normalizeBaseFont(cidBase);
      }
    }
    this.family = PdfStdFonts.familyOf(this.baseFont);
    this.bold = PdfStdFonts.boldByName(this.baseFont);
    this.italic = PdfStdFonts.italicByName(this.baseFont);
    this.applyDescriptor(doc, doc.dictGet(cidFont, 'FontDescriptor'));

    this.cmap = PdfFont.loadEncodingCMap(doc, doc.dictGet(dict, 'Encoding'));
    if (cidFont.isDict()) {
      this.defaultWidth = doc.numberOf(cidFont, 'DW', 1000);
      this.loadCidWidths(doc, doc.dictGet(cidFont, 'W').asArray());
    }
  }

  /**
   * 解析 /W 数组：两种写法混排
   *  - `c [w1 w2 ...]`：从 CID c 开始逐个给宽度；
   *  - `cFirst cLast w`：区间内统一宽度。
   */
  private loadCidWidths(doc: PdfDocument, w: PdfObj[]): void {
    let i = 0;
    while (i < w.length) {
      const first = doc.resolve(w[i]);
      if (!first.isNumber()) {
        i++;
        continue;
      }
      if (i + 1 >= w.length) {
        break;
      }
      const second = doc.resolve(w[i + 1]);
      if (second.isArray()) {
        const list = second.asArray();
        const startCid = first.asInt(0);
        for (let k = 0; k < list.length; k++) {
          const width = doc.resolve(list[k]).asNumber(-1);
          if (width >= 0) {
            this.cidWidths.set(startCid + k, width);
          }
        }
        i += 2;
        continue;
      }
      if (i + 2 >= w.length) {
        break;
      }
      const width = doc.resolve(w[i + 2]).asNumber(-1);
      const lo = first.asInt(0);
      const hi = second.asInt(0);
      // 区间可能很大（比如整套 CJK），逐个塞 Map 会爆内存，超过 2048 就记成区间近似
      if (width >= 0 && hi >= lo) {
        const count = hi - lo;
        if (count <= 2048) {
          for (let c = lo; c <= hi; c++) {
            this.cidWidths.set(c, width);
          }
        } else {
          // 大区间：只记两端，查询时按默认宽度处理（几乎都等于 DW）
          this.cidWidths.set(lo, width);
          this.cidWidths.set(hi, width);
          if (this.defaultWidth === 1000) {
            this.defaultWidth = width;
          }
        }
      }
      i += 3;
    }
  }

  /** 解析 Type0 的 /Encoding：预定义 CMap 名或内嵌 CMap 流 */
  private static loadEncodingCMap(doc: PdfDocument, encoding: PdfObj): PdfCMap {
    const cmap = new PdfCMap();
    if (encoding.isName()) {
      const name = encoding.asName();
      if (name === 'Identity-H' || name === 'Identity-V') {
        cmap.identity = true;
        cmap.defaultBytes = 2;
        return cmap;
      }
      // UniXXX-UCS2-H / UniXXX-UTF16-H：码位就是 UTF-16 编码单元
      if (name.startsWith('Uni') && (name.indexOf('UCS2') >= 0 || name.indexOf('UTF16') >= 0)) {
        cmap.identity = true;
        cmap.unicodeCodes = true;
        cmap.defaultBytes = 2;
        return cmap;
      }
      // 其他预定义 CJK CMap（GBK-EUC-H 等）：按双字节处理，文本靠 ToUnicode
      cmap.identity = true;
      cmap.defaultBytes = 2;
      return cmap;
    }
    if (encoding.isStream()) {
      PdfFont.parseCMapStream(doc.getStreamData(encoding), cmap);
      // usecmap 指向的父 CMap 这里不追（少见），保证有默认字节数即可
      if (cmap.ranges.length === 0 && cmap.cidRanges.length === 0 && cmap.single.size === 0) {
        cmap.identity = true;
      }
      return cmap;
    }
    cmap.identity = true;
    return cmap;
  }

  /**
   * 解析 CMap 流：只取 codespacerange / cidrange / cidchar 三种块。
   * CMap 是 PostScript 语法，但我们只需要「记号序列」，用 PDF 词法器足够。
   */
  private static parseCMapStream(data: Uint8Array, cmap: PdfCMap): void {
    const lexer = new PdfLexer(data, 0, data.length);
    // 用一个小滑动窗口保存最近的操作数
    const operands: PdfObj[] = [];
    let mode = 0; // 1 = codespacerange, 2 = cidrange, 3 = cidchar
    while (true) {
      const token = lexer.nextToken();
      if (token === null) {
        break;
      }
      if (token.kind === PdfKind.KEYWORD) {
        const kw = token.name;
        if (kw === 'begincodespacerange') {
          mode = 1;
          operands.length = 0;
          continue;
        }
        if (kw === 'begincidrange') {
          mode = 2;
          operands.length = 0;
          continue;
        }
        if (kw === 'begincidchar') {
          mode = 3;
          operands.length = 0;
          continue;
        }
        if (kw.startsWith('end')) {
          PdfFont.flushCMapBlock(mode, operands, cmap);
          mode = 0;
          operands.length = 0;
          continue;
        }
        operands.length = 0;
        continue;
      }
      if (mode !== 0) {
        operands.push(token);
        if (operands.length > 3000) {
          PdfFont.flushCMapBlock(mode, operands, cmap);
          operands.length = 0;
        }
      }
    }
  }

  /** 把一个 CMap 块里攒的操作数转成映射 */
  private static flushCMapBlock(mode: number, operands: PdfObj[], cmap: PdfCMap): void {
    if (mode === 1) {
      for (let i = 0; i + 1 < operands.length; i += 2) {
        const lo = operands[i];
        const hi = operands[i + 1];
        if (!lo.isString() || !hi.isString()) {
          continue;
        }
        const range = new CodespaceRange();
        range.bytes = Math.max(1, lo.asBytes().length);
        range.low = PdfFont.bytesToCode(lo.asBytes());
        range.high = PdfFont.bytesToCode(hi.asBytes());
        cmap.ranges.push(range);
      }
      return;
    }
    if (mode === 2) {
      for (let i = 0; i + 2 < operands.length; i += 3) {
        const lo = operands[i];
        const hi = operands[i + 1];
        const cid = operands[i + 2];
        if (!lo.isString() || !hi.isString() || !cid.isNumber()) {
          continue;
        }
        const r = new CidRange();
        r.low = PdfFont.bytesToCode(lo.asBytes());
        r.high = PdfFont.bytesToCode(hi.asBytes());
        r.cid = cid.asInt(0);
        cmap.cidRanges.push(r);
      }
      return;
    }
    if (mode === 3) {
      for (let i = 0; i + 1 < operands.length; i += 2) {
        const code = operands[i];
        const cid = operands[i + 1];
        if (!code.isString() || !cid.isNumber()) {
          continue;
        }
        cmap.single.set(PdfFont.bytesToCode(code.asBytes()), cid.asInt(0));
      }
    }
  }

  /** 大端字节 → 整数码位 */
  private static bytesToCode(bytes: Uint8Array): number {
    let v = 0;
    for (let i = 0; i < bytes.length && i < 4; i++) {
      v = v * 256 + bytes[i];
    }
    return v;
  }

  /** 大端字节 → UTF-16BE 文本（ToUnicode 的目标值都是 UTF-16BE） */
  private static bytesToText(bytes: Uint8Array): string {
    let s = '';
    for (let i = 0; i + 1 < bytes.length; i += 2) {
      s += String.fromCharCode(bytes[i] * 256 + bytes[i + 1]);
    }
    if (bytes.length === 1) {
      s = String.fromCharCode(bytes[0]);
    }
    return s;
  }

  /** 解析 /ToUnicode CMap（bfchar / bfrange） */
  private loadToUnicode(doc: PdfDocument, dict: PdfObj): void {
    const stream = doc.dictGet(dict, 'ToUnicode');
    if (!stream.isStream()) {
      return;
    }
    const data = doc.getStreamData(stream);
    if (data.length === 0) {
      return;
    }
    const map = new Map<number, string>();
    const lexer = new PdfLexer(data, 0, data.length);
    const operands: PdfObj[] = [];
    let mode = 0; // 1 = bfchar, 2 = bfrange
    while (true) {
      const token = lexer.nextToken();
      if (token === null) {
        break;
      }
      if (token.kind === PdfKind.KEYWORD) {
        const kw = token.name;
        if (kw === 'beginbfchar') {
          mode = 1;
          operands.length = 0;
          continue;
        }
        if (kw === 'beginbfrange') {
          mode = 2;
          operands.length = 0;
          continue;
        }
        if (kw.startsWith('end')) {
          PdfFont.flushBfBlock(mode, operands, map);
          mode = 0;
          operands.length = 0;
          continue;
        }
        if (kw === '[') {
          operands.push(PdfObj.ofKeyword('['));
          continue;
        }
        if (kw === ']') {
          operands.push(PdfObj.ofKeyword(']'));
          continue;
        }
        operands.length = 0;
        continue;
      }
      if (mode !== 0) {
        operands.push(token);
        if (operands.length > 3000) {
          PdfFont.flushBfBlock(mode, operands, map);
          operands.length = 0;
        }
      }
    }
    if (map.size > 0) {
      this.toUnicode = map;
    }
  }

  /** 把 bfchar / bfrange 块的操作数转成码位 → 文本 */
  private static flushBfBlock(mode: number, operands: PdfObj[], map: Map<number, string>): void {
    if (mode === 1) {
      for (let i = 0; i + 1 < operands.length; i += 2) {
        const src = operands[i];
        const dst = operands[i + 1];
        if (!src.isString()) {
          continue;
        }
        if (dst.isString()) {
          map.set(PdfFont.bytesToCode(src.asBytes()), PdfFont.bytesToText(dst.asBytes()));
        } else if (dst.isName()) {
          const uni = PdfStdFonts.glyphUnicode(dst.asName());
          if (uni >= 0) {
            map.set(PdfFont.bytesToCode(src.asBytes()), String.fromCharCode(uni));
          }
        }
      }
      return;
    }
    if (mode !== 2) {
      return;
    }
    // bfrange：`<lo> <hi> <dstStart>` 或 `<lo> <hi> [<d1> <d2> ...]`
    let i = 0;
    while (i + 2 < operands.length) {
      const lo = operands[i];
      const hi = operands[i + 1];
      if (!lo.isString() || !hi.isString()) {
        i++;
        continue;
      }
      const low = PdfFont.bytesToCode(lo.asBytes());
      const high = PdfFont.bytesToCode(hi.asBytes());
      const third = operands[i + 2];
      if (third.isKeyword() && third.name === '[') {
        // 数组形式：逐个码位一个目标
        let k = i + 3;
        let code = low;
        while (k < operands.length) {
          const item = operands[k];
          if (item.isKeyword() && item.name === ']') {
            k++;
            break;
          }
          if (item.isString() && code <= high) {
            map.set(code, PdfFont.bytesToText(item.asBytes()));
            code++;
          }
          k++;
        }
        i = k;
        continue;
      }
      if (third.isString()) {
        const dst = third.asBytes();
        const base = PdfFont.bytesToText(dst);
        const count = high - low;
        if (count >= 0 && count < 65536 && base.length > 0) {
          const lastCode = base.charCodeAt(base.length - 1);
          const prefix = base.substring(0, base.length - 1);
          for (let c = 0; c <= count; c++) {
            // 目标文本的最后一个编码单元递增（PDF 32000-1 9.10.3）
            map.set(low + c, prefix + String.fromCharCode((lastCode + c) & 0xffff));
          }
        }
        i += 3;
        continue;
      }
      i += 3;
    }
  }

  /** 当前位置的码占几个字节（简单字体固定 1） */
  codeLengthAt(data: Uint8Array, i: number): number {
    if (!this.isComposite || this.cmap === null) {
      return 1;
    }
    return this.cmap.bytesAt(data, i);
  }

  /** 取码位值 */
  static codeAt(data: Uint8Array, i: number, length: number): number {
    let v = 0;
    for (let k = 0; k < length && i + k < data.length; k++) {
      v = v * 256 + data[i + k];
    }
    return v;
  }

  /**
   * 码位的前进宽度（单位 1/1000 em）。
   * 查不到就按标准字体表 / Unicode 估算，绝不返回 0，否则文字会叠在一起。
   */
  widthOf(code: number): number {
    const cached = this.widthCache.get(code);
    if (cached !== undefined) {
      return cached;
    }
    let w = -1;
    if (this.isComposite) {
      const cid = this.cmap === null ? code : this.cmap.cidOf(code);
      const declared = this.cidWidths.get(cid);
      w = declared === undefined ? this.defaultWidth : declared;
    } else {
      if (this.simpleWidths !== null && code >= 0 && code < 256) {
        w = this.simpleWidths[code];
      }
      if (w < 0 && this.glyphNames !== null && code >= 0 && code < 256) {
        const name = this.glyphNames[code];
        if (name.length > 0) {
          w = PdfStdFonts.glyphWidth(this.family, this.bold, this.italic, name);
        }
      }
      if (w < 0 && this.missingWidth >= 0) {
        w = this.missingWidth;
      }
      if (w < 0) {
        w = PdfStdFonts.estimateWidth(PdfFont.firstCharCode(this.textOf(code)));
      }
    }
    if (!(w >= 0)) {
      w = 500;
    }
    this.widthCache.set(code, w);
    return w;
  }

  /** 取字符串首字符的码点（可能是代理对） */
  private static firstCharCode(text: string): number {
    if (text.length === 0) {
      return -1;
    }
    const c = text.charCodeAt(0);
    if (c >= 0xd800 && c <= 0xdbff && text.length > 1) {
      const low = text.charCodeAt(1);
      return 0x10000 + (c - 0xd800) * 0x400 + (low - 0xdc00);
    }
    return c;
  }

  /**
   * 码位 → 可显示文本。
   *
   * 优先级：ToUnicode → 字形名查 AGL → CMap 声明码位即 Unicode → 按单字节 Latin-1。
   * 拿不到任何映射时返回空串（该字符不画，但宽度照样前进，版式不会乱）。
   */
  textOf(code: number): string {
    if (this.toUnicode !== null) {
      const t = this.toUnicode.get(code);
      if (t !== undefined && t.length > 0) {
        // 部分文档用 0xFFFD/0x0000 占位，视为不可显示
        const first = t.charCodeAt(0);
        if (first !== 0 && first !== 0xfffd) {
          return t;
        }
        return '';
      }
    }
    if (!this.isComposite) {
      if (this.glyphNames !== null && code >= 0 && code < 256) {
        const name = this.glyphNames[code];
        if (name.length > 0) {
          const uni = PdfStdFonts.glyphUnicode(name);
          if (uni > 0) {
            return String.fromCharCode(uni);
          }
          return '';
        }
      }
      if (code >= 32 && code < 256) {
        return String.fromCharCode(code);
      }
      return '';
    }
    if (this.cmap !== null && this.cmap.unicodeCodes) {
      return String.fromCharCode(code);
    }
    // Identity-H 且没有 ToUnicode：CID 就是字形号，无法还原文本
    return '';
  }

  /** 是否是「单字节 32」——只有它会吃 Tw 字间距（PDF 32000-1 9.3.3） */
  isWordSpaceCode(code: number, length: number): boolean {
    return length === 1 && code === 32;
  }
}

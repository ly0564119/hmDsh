/**
 * PDF 文档解析：交叉引用表 / 交叉引用流 / 对象流 / 页树。
 *
 * 解析顺序按 PDF 32000-1 第 7.5 节：
 *  1. 文件尾 `startxref` 给出交叉引用表偏移；
 *  2. 交叉引用可能是传统 `xref` 表，也可能是 PDF 1.5 起的交叉引用流（/Type /XRef）；
 *  3. 沿 /Prev（以及混合文件的 /XRefStm）向前串联，先出现的条目优先（新版本覆盖旧版本）；
 *  4. 对象可能不在文件里直接存放，而是压在对象流（/Type /ObjStm）中。
 *
 * 稳健性优先：交叉引用坏了（很常见，比如被别的工具截断过）就退化成
 * 「全文件扫描 `N G obj`」重建索引，只要对象本身还在就能打开。
 */

import { PdfFilters, PdfImageFilter, PdfPredictorParams } from './PdfFilters';
import { PdfLexer, PdfParser } from './PdfLexer';
import { PdfKind, PdfObj } from './PdfObject';

/** 交叉引用条目 */
class XrefEntry {
  /** 1 = 文件内偏移，2 = 在对象流里 */
  type: number = 1;
  /** type=1：文件偏移；type=2：所在对象流的对象号 */
  offset: number = 0;
  /** type=2：在对象流中的序号 */
  index: number = 0;
}

/** 一页的基本信息（页字典 + 继承来的属性） */
export class PdfPageInfo {
  /** 页字典 */
  readonly dict: PdfObj;
  /** 裁剪框（优先 CropBox，退回 MediaBox），单位 pt，顺序为 [llx, lly, urx, ury] */
  readonly box: number[];
  /** 页面旋转角度（0/90/180/270） */
  readonly rotate: number;
  /** 资源字典（可能是从父节点继承的） */
  readonly resources: PdfObj;

  constructor(dict: PdfObj, box: number[], rotate: number, resources: PdfObj) {
    this.dict = dict;
    this.box = box;
    this.rotate = rotate;
    this.resources = resources;
  }

  /** 显示宽度（pt，已考虑旋转） */
  get widthPt(): number {
    const w = Math.abs(this.box[2] - this.box[0]);
    const h = Math.abs(this.box[3] - this.box[1]);
    return (this.rotate === 90 || this.rotate === 270) ? h : w;
  }

  /** 显示高度（pt，已考虑旋转） */
  get heightPt(): number {
    const w = Math.abs(this.box[2] - this.box[0]);
    const h = Math.abs(this.box[3] - this.box[1]);
    return (this.rotate === 90 || this.rotate === 270) ? w : h;
  }
}

export class PdfDocument {
  private readonly data: Uint8Array;
  /** 对象号 → 交叉引用条目 */
  private readonly xref: Map<number, XrefEntry> = new Map<number, XrefEntry>();
  /** 已解析对象缓存 */
  private readonly cache: Map<number, PdfObj> = new Map<number, PdfObj>();
  /** 对象流缓存：对象流号 → （对象号 → 对象） */
  private readonly objStmCache: Map<number, Map<number, PdfObj>> = new Map<number, Map<number, PdfObj>>();
  /** 流解码结果缓存，避免同一个流（如字体、图片）被反复解码 */
  private readonly streamCache: Map<PdfObj, Uint8Array> = new Map<PdfObj, Uint8Array>();
  /** 文件尾字典（合并了各代 trailer 的键） */
  private trailer: PdfObj = PdfObj.ofDict(new Map<string, PdfObj>());
  /** `%PDF-` 头在文件中的偏移，非 0 时所有对象偏移都要跟着平移 */
  private headerOffset: number = 0;
  /** 是否已经做过全文件重建 */
  private rebuilt: boolean = false;
  /** 页列表（惰性构建） */
  private pageList: PdfPageInfo[] | null = null;
  /** PDF 版本号文本，如 "1.7" */
  version: string = '';

  private constructor(data: Uint8Array) {
    this.data = data;
  }

  /**
   * 打开一个内存中的 PDF。
   * @throws 文件不是 PDF、已加密、或完全无法恢复时抛出带中文说明的错误
   */
  static open(data: Uint8Array): PdfDocument {
    const doc = new PdfDocument(data);
    doc.readHeader();
    try {
      doc.readXrefChain();
    } catch (e) {
      doc.rebuild();
    }
    if (doc.trailer.get('Root').isNull()) {
      doc.rebuild();
    }
    if (!doc.trailer.get('Encrypt').isNull()) {
      throw new Error('这个 PDF 有加密保护，暂不支持打印；请先用阅读器去掉密码后再试');
    }
    return doc;
  }

  /** 找 `%PDF-` 头，顺带取版本号；头前面可能有垃圾字节（下载器加的） */
  private readHeader(): void {
    const limit = Math.min(this.data.length, 4096);
    for (let i = 0; i + 5 <= limit; i++) {
      if (this.data[i] === 0x25 && this.data[i + 1] === 0x50 && this.data[i + 2] === 0x44 &&
        this.data[i + 3] === 0x46 && this.data[i + 4] === 0x2d) {
        this.headerOffset = i;
        let v = '';
        for (let k = i + 5; k < Math.min(i + 13, this.data.length); k++) {
          const c = this.data[k];
          if ((c >= 0x30 && c <= 0x39) || c === 0x2e) {
            v += String.fromCharCode(c);
          } else {
            break;
          }
        }
        this.version = v;
        return;
      }
    }
    throw new Error('这不是有效的 PDF 文件（找不到 %PDF 文件头）');
  }

  /** 从文件尾找最后一个 `startxref` 的值 */
  private findStartXref(): number {
    const tailStart = Math.max(0, this.data.length - 2048);
    let found = -1;
    for (let i = this.data.length - 9; i >= tailStart; i--) {
      if (this.matchAscii(i, 'startxref')) {
        found = i;
        break;
      }
    }
    if (found < 0) {
      throw new Error('PDF 文件尾缺少 startxref');
    }
    const lexer = new PdfLexer(this.data, found + 9, this.data.length);
    const token = lexer.nextToken();
    if (token === null || token.kind !== PdfKind.NUMBER) {
      throw new Error('PDF 的 startxref 不是数字');
    }
    return Math.trunc(token.num);
  }

  /** 指定偏移处是否是给定 ASCII 串 */
  private matchAscii(offset: number, text: string): boolean {
    if (offset < 0 || offset + text.length > this.data.length) {
      return false;
    }
    for (let i = 0; i < text.length; i++) {
      if (this.data[offset + i] !== text.charCodeAt(i)) {
        return false;
      }
    }
    return true;
  }

  /** 沿 /Prev 链读完所有交叉引用段 */
  private readXrefChain(): void {
    let offset = this.findStartXref() + this.headerOffset;
    const seen = new Map<number, boolean>();
    let guard = 0;
    while (offset > 0 && offset < this.data.length && guard < 64) {
      guard++;
      if (seen.has(offset)) {
        break; // 防止 /Prev 成环
      }
      seen.set(offset, true);
      const trailer = this.readXrefSection(offset);
      if (trailer === null) {
        break;
      }
      this.mergeTrailer(trailer);
      // 混合文件：传统表 + 交叉引用流并存
      const xrefStm = trailer.get('XRefStm');
      if (xrefStm.isNumber()) {
        const stmOffset = xrefStm.asInt(0) + this.headerOffset;
        if (!seen.has(stmOffset)) {
          seen.set(stmOffset, true);
          const t2 = this.readXrefSection(stmOffset);
          if (t2 !== null) {
            this.mergeTrailer(t2);
          }
        }
      }
      const prev = trailer.get('Prev');
      if (!prev.isNumber()) {
        break;
      }
      offset = prev.asInt(0) + this.headerOffset;
    }
    if (this.xref.size === 0) {
      throw new Error('PDF 交叉引用表为空');
    }
  }

  /** 后出现的段是更旧的版本，已有的键/条目不覆盖 */
  private mergeTrailer(trailer: PdfObj): void {
    const keys = trailer.keys();
    for (let i = 0; i < keys.length; i++) {
      if (!this.trailer.has(keys[i])) {
        this.trailer.set(keys[i], trailer.get(keys[i]));
      }
    }
  }

  /**
   * 读一个交叉引用段。
   * @returns 该段的 trailer 字典；读失败返回 null
   */
  private readXrefSection(offset: number): PdfObj | null {
    const lexer = new PdfLexer(this.data, offset, this.data.length);
    lexer.skipWhite();
    if (this.matchAscii(lexer.pos, 'xref')) {
      return this.readXrefTable(lexer.pos + 4);
    }
    // 交叉引用流：`N G obj << ... >> stream`
    const obj = this.parseIndirectAt(offset, -1);
    if (obj === null || !obj.isStream()) {
      return null;
    }
    this.readXrefStream(obj);
    return PdfObj.ofDict(obj.map === null ? new Map<string, PdfObj>() : obj.map);
  }

  /** 读传统 `xref` 表 */
  private readXrefTable(offset: number): PdfObj | null {
    const lexer = new PdfLexer(this.data, offset, this.data.length);
    while (true) {
      lexer.skipWhite();
      if (this.matchAscii(lexer.pos, 'trailer')) {
        const parser = PdfParser.fromBytes(this.data, lexer.pos + 7, this.data.length);
        const dict = parser.parseObject();
        return (dict !== null && dict.isDict()) ? dict : PdfObj.ofDict(new Map<string, PdfObj>());
      }
      const first = lexer.nextToken();
      if (first === null || first.kind !== PdfKind.NUMBER) {
        return PdfObj.ofDict(new Map<string, PdfObj>());
      }
      const count = lexer.nextToken();
      if (count === null || count.kind !== PdfKind.NUMBER) {
        return PdfObj.ofDict(new Map<string, PdfObj>());
      }
      const startNum = Math.trunc(first.num);
      const total = Math.trunc(count.num);
      for (let i = 0; i < total; i++) {
        const a = lexer.nextToken();
        const b = lexer.nextToken();
        lexer.skipWhite();
        // 第三个字段是 'n'（在用）或 'f'（空闲）
        const typeChar = lexer.pos < this.data.length ? this.data[lexer.pos] : 0x66;
        lexer.pos++;
        if (a === null || b === null || a.kind !== PdfKind.NUMBER) {
          return PdfObj.ofDict(new Map<string, PdfObj>());
        }
        if (typeChar !== 0x6e) {
          continue; // 空闲条目跳过
        }
        const num = startNum + i;
        if (this.xref.has(num)) {
          continue; // 新版本优先
        }
        const entry = new XrefEntry();
        entry.type = 1;
        entry.offset = Math.trunc(a.num) + this.headerOffset;
        this.xref.set(num, entry);
      }
    }
  }

  /** 读交叉引用流（/Type /XRef），字段宽度由 /W 给出 */
  private readXrefStream(stream: PdfObj): void {
    const data = this.getStreamData(stream);
    const wArr = this.resolve(stream.get('W')).asArray();
    if (wArr.length < 3) {
      return;
    }
    const w0 = wArr[0].asInt(0);
    const w1 = wArr[1].asInt(0);
    const w2 = wArr[2].asInt(0);
    const rowBytes = w0 + w1 + w2;
    if (rowBytes <= 0) {
      return;
    }
    // /Index 给出 [起始对象号, 个数] 的成对列表，缺省是 [0, Size]
    const indexArr = this.resolve(stream.get('Index')).asArray();
    const ranges: number[] = [];
    if (indexArr.length >= 2) {
      for (let i = 0; i + 1 < indexArr.length; i += 2) {
        ranges.push(indexArr[i].asInt(0), indexArr[i + 1].asInt(0));
      }
    } else {
      ranges.push(0, this.resolve(stream.get('Size')).asInt(0));
    }

    let pos = 0;
    for (let r = 0; r + 1 < ranges.length; r += 2) {
      const start = ranges[r];
      const count = ranges[r + 1];
      for (let i = 0; i < count; i++) {
        if (pos + rowBytes > data.length) {
          return;
        }
        // 字段宽度为 0 时按默认值：type 默认 1
        let type = 1;
        if (w0 > 0) {
          type = PdfDocument.readBE(data, pos, w0);
        }
        const f2 = PdfDocument.readBE(data, pos + w0, w1);
        const f3 = PdfDocument.readBE(data, pos + w0 + w1, w2);
        pos += rowBytes;
        const num = start + i;
        if (this.xref.has(num)) {
          continue;
        }
        if (type === 1) {
          const entry = new XrefEntry();
          entry.type = 1;
          entry.offset = f2 + this.headerOffset;
          this.xref.set(num, entry);
        } else if (type === 2) {
          const entry = new XrefEntry();
          entry.type = 2;
          entry.offset = f2; // 对象流的对象号
          entry.index = f3;
          this.xref.set(num, entry);
        }
      }
    }
  }

  /** 读大端整数（交叉引用流的字段都是大端） */
  private static readBE(data: Uint8Array, offset: number, width: number): number {
    let v = 0;
    for (let i = 0; i < width; i++) {
      v = v * 256 + data[offset + i];
    }
    return v;
  }

  /**
   * 全文件扫描重建索引：找所有 `N G obj`，以及 trailer / 根对象。
   * 交叉引用被破坏时的兜底路径，成本是一次全文扫描。
   */
  private rebuild(): void {
    if (this.rebuilt) {
      return;
    }
    this.rebuilt = true;
    this.xref.clear();
    this.cache.clear();
    this.objStmCache.clear();
    const data = this.data;
    for (let i = 0; i + 3 < data.length; i++) {
      // 找 "obj" 且前面是「数字 空白 数字 空白」
      if (data[i] !== 0x6f || data[i + 1] !== 0x62 || data[i + 2] !== 0x6a) {
        continue;
      }
      let p = i - 1;
      while (p >= 0 && PdfLexer.isWhite(data[p])) {
        p--;
      }
      let genEnd = p + 1;
      while (p >= 0 && data[p] >= 0x30 && data[p] <= 0x39) {
        p--;
      }
      const genStart = p + 1;
      if (genStart === genEnd) {
        continue;
      }
      while (p >= 0 && PdfLexer.isWhite(data[p])) {
        p--;
      }
      let numEnd = p + 1;
      while (p >= 0 && data[p] >= 0x30 && data[p] <= 0x39) {
        p--;
      }
      const numStart = p + 1;
      if (numStart === numEnd) {
        continue;
      }
      let num = 0;
      for (let k = numStart; k < numEnd; k++) {
        num = num * 10 + (data[k] - 0x30);
      }
      // 后出现的同号对象是更新版本，直接覆盖
      const entry = new XrefEntry();
      entry.type = 1;
      entry.offset = numStart;
      this.xref.set(num, entry);
    }

    // 找 trailer 字典（可能有多个，取最后一个能给出 /Root 的）
    let root = PdfObj.NULL_OBJ;
    const newTrailer = new Map<string, PdfObj>();
    for (let i = this.data.length - 7; i >= 0; i--) {
      if (!this.matchAscii(i, 'trailer')) {
        continue;
      }
      const parser = PdfParser.fromBytes(this.data, i + 7, this.data.length);
      const dict = parser.parseObject();
      if (dict !== null && dict.isDict() && !dict.get('Root').isNull()) {
        root = dict.get('Root');
        const keys = dict.keys();
        for (let k = 0; k < keys.length; k++) {
          newTrailer.set(keys[k], dict.get(keys[k]));
        }
        break;
      }
    }
    this.trailer = PdfObj.ofDict(newTrailer);

    if (root.isNull()) {
      // 没有 trailer（交叉引用流的文件就没有）：扫所有对象找 /Type /Catalog
      const nums = this.objectNumbers();
      for (let i = 0; i < nums.length; i++) {
        const obj = this.getObject(nums[i]);
        if (obj.isDict()) {
          if (this.resolve(obj.get('Type')).asName() === 'Catalog') {
            this.trailer.set('Root', PdfObj.ofRef(nums[i], 0));
            root = this.trailer.get('Root');
            break;
          }
          // 交叉引用流里也带着 /Root
          if (this.resolve(obj.get('Type')).asName() === 'XRef' && !obj.get('Root').isNull()) {
            this.trailer.set('Root', obj.get('Root'));
            root = this.trailer.get('Root');
          }
        }
      }
    }
    if (root.isNull()) {
      // 连 Catalog 都没有：留给页树构建阶段按 /Type /Page 兜底
      this.trailer.set('Root', PdfObj.NULL_OBJ);
    }
  }

  /** 当前索引里的全部对象号（升序） */
  private objectNumbers(): number[] {
    const nums: number[] = [];
    this.xref.forEach((entry: XrefEntry, num: number) => {
      nums.push(num);
    });
    nums.sort((a: number, b: number) => a - b);
    return nums;
  }

  /**
   * 解析指定偏移处的间接对象。
   * @param expectNum 期望的对象号，-1 表示不校验
   * @returns 对象值；失败返回 null
   */
  private parseIndirectAt(offset: number, expectNum: number): PdfObj | null {
    if (offset < 0 || offset >= this.data.length) {
      return null;
    }
    const parser = PdfParser.fromBytes(this.data, offset, this.data.length);
    const numTok = parser.parseObject();
    if (numTok === null || numTok.kind !== PdfKind.NUMBER) {
      return null;
    }
    // `N G obj` 会被语法层当成 "数字 数字 关键字"，第一个记号就是对象号
    if (expectNum >= 0 && Math.trunc(numTok.num) !== expectNum) {
      return null;
    }
    const genTok = parser.parseObject();
    if (genTok === null) {
      return null;
    }
    let kw = '';
    if (genTok.kind === PdfKind.KEYWORD) {
      kw = genTok.name;
    } else {
      kw = parser.nextKeyword();
    }
    if (kw !== 'obj') {
      return null;
    }
    const value = parser.parseObject();
    if (value === null) {
      return null;
    }
    if (value.kind === PdfKind.KEYWORD) {
      return null;
    }
    // 字典后面可能紧跟 stream
    if (value.isDict()) {
      const next = parser.nextKeyword();
      if (next === 'stream') {
        return this.readStreamBody(value, parser.lexer);
      }
    }
    return value;
  }

  /**
   * 读流数据：`stream` 关键字之后是 EOL，然后是 /Length 字节的原始数据。
   * /Length 不可信（可能是间接引用，也可能干脆是错的），所以要校验 `endstream`。
   */
  private readStreamBody(dict: PdfObj, lexer: PdfLexer): PdfObj {
    lexer.skipEol();
    const start = lexer.pos;
    let length = this.resolve(dict.get('Length')).asInt(-1);
    let end = length >= 0 ? start + length : -1;
    if (end < 0 || end > this.data.length || !this.endstreamNear(end)) {
      end = this.findEndstream(start);
    }
    const raw = this.data.subarray(start, end);
    return PdfObj.ofStream(dict.map === null ? new Map<string, PdfObj>() : dict.map, raw);
  }

  /** /Length 指到的位置附近是否真的是 endstream（允许几个空白字符） */
  private endstreamNear(end: number): boolean {
    let p = end;
    let guard = 0;
    while (p < this.data.length && guard < 4 && PdfLexer.isWhite(this.data[p])) {
      p++;
      guard++;
    }
    return this.matchAscii(p, 'endstream');
  }

  /** 从 start 起向后找 `endstream`，返回数据结束位置（去掉紧邻的换行） */
  private findEndstream(start: number): number {
    for (let i = start; i + 9 <= this.data.length; i++) {
      if (this.data[i] === 0x65 && this.matchAscii(i, 'endstream')) {
        let e = i;
        if (e > start && this.data[e - 1] === 0x0a) {
          e--;
        }
        if (e > start && this.data[e - 1] === 0x0d) {
          e--;
        }
        return e;
      }
    }
    return this.data.length;
  }

  /** 按对象号取对象（带缓存），取不到返回 NULL_OBJ */
  getObject(num: number): PdfObj {
    const cached = this.cache.get(num);
    if (cached !== undefined) {
      return cached;
    }
    // 先占位，避免对象互相引用时无限递归
    this.cache.set(num, PdfObj.NULL_OBJ);
    let result: PdfObj = PdfObj.NULL_OBJ;
    const entry = this.xref.get(num);
    if (entry !== undefined) {
      if (entry.type === 1) {
        const parsed = this.parseIndirectAt(entry.offset, num);
        if (parsed !== null) {
          result = parsed;
        }
      } else {
        result = this.getFromObjectStream(entry.offset, num);
      }
    }
    if (result.isNull() && !this.rebuilt) {
      // 偏移不对：重建一次索引再试
      const savedTrailer = this.trailer;
      this.rebuild();
      if (this.trailer.get('Root').isNull()) {
        this.trailer = savedTrailer;
      }
      const retry = this.xref.get(num);
      if (retry !== undefined && retry.type === 1) {
        const parsed = this.parseIndirectAt(retry.offset, num);
        if (parsed !== null) {
          result = parsed;
        }
      }
    }
    this.cache.set(num, result);
    return result;
  }

  /** 从对象流里取对象 */
  private getFromObjectStream(stmNum: number, num: number): PdfObj {
    let table = this.objStmCache.get(stmNum);
    if (table === undefined) {
      table = this.parseObjectStream(stmNum);
      this.objStmCache.set(stmNum, table);
    }
    const obj = table.get(num);
    return obj === undefined ? PdfObj.NULL_OBJ : obj;
  }

  /** 解析对象流：头部是 N 组「对象号 偏移」，正文从 /First 开始 */
  private parseObjectStream(stmNum: number): Map<number, PdfObj> {
    const table = new Map<number, PdfObj>();
    const stream = this.getObject(stmNum);
    if (!stream.isStream()) {
      return table;
    }
    const data = this.getStreamData(stream);
    const n = this.resolve(stream.get('N')).asInt(0);
    const first = this.resolve(stream.get('First')).asInt(0);
    if (n <= 0 || first <= 0 || data.length === 0) {
      return table;
    }
    const headerLexer = new PdfLexer(data, 0, first);
    const nums: number[] = [];
    const offsets: number[] = [];
    for (let i = 0; i < n; i++) {
      const a = headerLexer.nextToken();
      const b = headerLexer.nextToken();
      if (a === null || b === null || a.kind !== PdfKind.NUMBER || b.kind !== PdfKind.NUMBER) {
        break;
      }
      nums.push(Math.trunc(a.num));
      offsets.push(Math.trunc(b.num));
    }
    for (let i = 0; i < nums.length; i++) {
      const start = first + offsets[i];
      const end = i + 1 < nums.length ? first + offsets[i + 1] : data.length;
      if (start >= data.length) {
        continue;
      }
      const parser = PdfParser.fromBytes(data, start, Math.min(end, data.length));
      const value = parser.parseObject();
      if (value !== null && value.kind !== PdfKind.KEYWORD) {
        table.set(nums[i], value);
      }
    }
    return table;
  }

  /** 解引用：一路跟着 `N G R` 取到真实对象 */
  resolve(obj: PdfObj): PdfObj {
    let cur = obj;
    let guard = 0;
    while (cur.isRef() && guard < 32) {
      cur = this.getObject(cur.refNum);
      guard++;
    }
    return cur;
  }

  /** 取字典里某键并解引用 */
  dictGet(dict: PdfObj, key: string): PdfObj {
    return this.resolve(dict.get(key));
  }

  /** 取数字（自动解引用） */
  numberOf(dict: PdfObj, key: string, fallback: number): number {
    const v = this.resolve(dict.get(key));
    return v.isNumber() ? v.num : fallback;
  }

  /**
   * 取流里的解码数据（按 /Filter 逐级解码，带缓存）。
   * 图像类过滤器（DCT/JPX/CCITT/JBIG2）不解码，原样返回，由调用方处理。
   */
  getStreamData(stream: PdfObj): Uint8Array {
    const cached = this.streamCache.get(stream);
    if (cached !== undefined) {
      return cached;
    }
    const result = this.decodeStream(stream, false);
    this.streamCache.set(stream, result.data);
    return result.data;
  }

  /**
   * 取图像流数据：与 getStreamData 相同，但会额外告知「停在了哪个图像过滤器」，
   * 让调用方知道剩下的字节是 JPEG 还是别的编码。
   */
  decodeImageStream(stream: PdfObj): PdfStreamResult {
    return this.decodeStream(stream, true);
  }

  /** 按 Filter 链解码 */
  private decodeStream(stream: PdfObj, forImage: boolean): PdfStreamResult {
    let data = stream.raw === null ? new Uint8Array(0) : stream.raw;
    const filterObj = this.resolve(stream.get('Filter'));
    const parmsObj = this.resolve(stream.get('DecodeParms').isNull()
      ? stream.get('DP') : stream.get('DecodeParms'));
    const filters: string[] = [];
    if (filterObj.isName()) {
      filters.push(filterObj.asName());
    } else if (filterObj.isArray()) {
      const arr = filterObj.asArray();
      for (let i = 0; i < arr.length; i++) {
        filters.push(this.resolve(arr[i]).asName());
      }
    }
    const parms: PdfObj[] = [];
    if (parmsObj.isArray()) {
      const arr = parmsObj.asArray();
      for (let i = 0; i < arr.length; i++) {
        parms.push(this.resolve(arr[i]));
      }
    } else {
      parms.push(parmsObj);
    }

    for (let i = 0; i < filters.length; i++) {
      const name = filters[i];
      const parm = i < parms.length ? parms[i] : PdfObj.NULL_OBJ;
      if (PdfImageFilter.isImageFilter(name)) {
        // 图像编码：到此为止
        return new PdfStreamResult(data, name, parm);
      }
      if (name === 'FlateDecode' || name === 'Fl') {
        data = PdfFilters.flate(data);
        data = this.applyPredictor(data, parm);
      } else if (name === 'LZWDecode' || name === 'LZW') {
        const early = this.numberOf(parm, 'EarlyChange', 1);
        data = PdfFilters.lzw(data, early);
        data = this.applyPredictor(data, parm);
      } else if (name === 'ASCII85Decode' || name === 'A85') {
        data = PdfFilters.ascii85(data);
      } else if (name === 'ASCIIHexDecode' || name === 'AHx') {
        data = PdfFilters.asciiHex(data);
      } else if (name === 'RunLengthDecode' || name === 'RL') {
        data = PdfFilters.runLength(data);
      } else if (name === 'Crypt' || name.length === 0) {
        // 身份加密过滤器 / 空名字：原样通过
      } else if (!forImage) {
        // 未知过滤器：只能原样返回，让上层尽量继续
      }
    }
    return new PdfStreamResult(data, PdfImageFilter.NONE, PdfObj.NULL_OBJ);
  }

  /** 按 DecodeParms 还原预测器 */
  private applyPredictor(data: Uint8Array, parm: PdfObj): Uint8Array {
    if (!parm.isDict()) {
      return data;
    }
    const predictor = this.numberOf(parm, 'Predictor', 1);
    if (predictor <= 1) {
      return data;
    }
    const params = new PdfPredictorParams();
    params.predictor = predictor;
    params.colors = this.numberOf(parm, 'Colors', 1);
    params.bitsPerComponent = this.numberOf(parm, 'BitsPerComponent', 8);
    params.columns = this.numberOf(parm, 'Columns', 1);
    return PdfFilters.applyPredictor(data, params);
  }

  /** 文档根字典（/Root → Catalog） */
  get catalog(): PdfObj {
    return this.resolve(this.trailer.get('Root'));
  }

  /**
   * 页列表。
   *
   * 正常走 /Root → /Pages 页树并继承 Resources / MediaBox / CropBox / Rotate；
   * 页树坏了就退化成「扫描所有 /Type /Page 对象」。
   */
  get pages(): PdfPageInfo[] {
    if (this.pageList !== null) {
      return this.pageList;
    }
    const list: PdfPageInfo[] = [];
    const root = this.catalog;
    const pagesRoot = this.resolve(root.get('Pages'));
    if (pagesRoot.isDict()) {
      const defaultBox: number[] = [0, 0, 612, 792];
      this.collectPages(pagesRoot, PdfObj.NULL_OBJ, defaultBox, 0, list, 0);
    }
    if (list.length === 0) {
      this.collectPagesByScan(list);
    }
    this.pageList = list;
    return list;
  }

  /** 递归遍历页树 */
  private collectPages(node: PdfObj, resources: PdfObj, box: number[], rotate: number,
    out: PdfPageInfo[], depth: number): void {
    if (depth > 32 || out.length > 4096) {
      return;
    }
    let inheritedRes = resources;
    const ownRes = this.resolve(node.get('Resources'));
    if (ownRes.isDict()) {
      inheritedRes = ownRes;
    }
    let inheritedBox = box;
    const cropBox = this.rectOf(node, 'CropBox');
    const mediaBox = this.rectOf(node, 'MediaBox');
    if (mediaBox !== null) {
      inheritedBox = mediaBox;
    }
    if (cropBox !== null) {
      inheritedBox = cropBox;
    }
    let inheritedRotate = rotate;
    const rotObj = this.resolve(node.get('Rotate'));
    if (rotObj.isNumber()) {
      inheritedRotate = PdfDocument.normalizeRotate(rotObj.asInt(0));
    }

    const type = this.resolve(node.get('Type')).asName();
    const kids = this.resolve(node.get('Kids'));
    if (type === 'Page' || (!kids.isArray() && node.has('Contents'))) {
      out.push(new PdfPageInfo(node, inheritedBox, inheritedRotate, inheritedRes));
      return;
    }
    const kidArr = kids.asArray();
    for (let i = 0; i < kidArr.length; i++) {
      const kid = this.resolve(kidArr[i]);
      if (kid.isDict()) {
        this.collectPages(kid, inheritedRes, inheritedBox, inheritedRotate, out, depth + 1);
      }
    }
  }

  /** 页树不可用时：全库扫描 /Type /Page */
  private collectPagesByScan(out: PdfPageInfo[]): void {
    this.rebuild();
    const nums = this.objectNumbers();
    for (let i = 0; i < nums.length; i++) {
      const obj = this.getObject(nums[i]);
      if (!obj.isDict()) {
        continue;
      }
      if (this.resolve(obj.get('Type')).asName() !== 'Page') {
        continue;
      }
      let box = this.rectOf(obj, 'CropBox');
      if (box === null) {
        box = this.rectOf(obj, 'MediaBox');
      }
      // 页尺寸可能在父节点上，向上找几层
      let parent = this.resolve(obj.get('Parent'));
      let guard = 0;
      let res = this.resolve(obj.get('Resources'));
      let rotate = 0;
      const rotObj = this.resolve(obj.get('Rotate'));
      if (rotObj.isNumber()) {
        rotate = PdfDocument.normalizeRotate(rotObj.asInt(0));
      }
      while (parent.isDict() && guard < 8) {
        if (box === null) {
          box = this.rectOf(parent, 'MediaBox');
        }
        if (!res.isDict()) {
          res = this.resolve(parent.get('Resources'));
        }
        parent = this.resolve(parent.get('Parent'));
        guard++;
      }
      if (box === null) {
        box = [0, 0, 612, 792];
      }
      out.push(new PdfPageInfo(obj, box, rotate, res));
    }
  }

  /** 取矩形属性（MediaBox / CropBox / BBox），并规范成 [llx, lly, urx, ury] */
  rectOf(dict: PdfObj, key: string): number[] | null {
    const arr = this.resolve(dict.get(key)).asArray();
    if (arr.length < 4) {
      return null;
    }
    const v0 = this.resolve(arr[0]).asNumber(0);
    const v1 = this.resolve(arr[1]).asNumber(0);
    const v2 = this.resolve(arr[2]).asNumber(0);
    const v3 = this.resolve(arr[3]).asNumber(0);
    const box: number[] = [Math.min(v0, v2), Math.min(v1, v3), Math.max(v0, v2), Math.max(v1, v3)];
    if (box[2] - box[0] < 1 || box[3] - box[1] < 1) {
      return null; // 退化的框（0 宽/0 高）当作没有
    }
    return box;
  }

  /** 旋转角规范到 0/90/180/270 */
  static normalizeRotate(value: number): number {
    let r = Math.trunc(value) % 360;
    if (r < 0) {
      r += 360;
    }
    r = Math.round(r / 90) * 90;
    return r === 360 ? 0 : r;
  }

  /**
   * 取某页的内容流字节（/Contents 可能是单个流也可能是流数组，数组要按顺序拼接）。
   * 拼接时要在各段之间补一个换行，否则末尾运算符会和下一段首个记号粘在一起。
   */
  pageContent(page: PdfPageInfo): Uint8Array {
    const contents = this.resolve(page.dict.get('Contents'));
    const parts: Uint8Array[] = [];
    if (contents.isStream()) {
      parts.push(this.getStreamData(contents));
    } else if (contents.isArray()) {
      const arr = contents.asArray();
      for (let i = 0; i < arr.length; i++) {
        const s = this.resolve(arr[i]);
        if (s.isStream()) {
          parts.push(this.getStreamData(s));
        }
      }
    }
    if (parts.length === 0) {
      return new Uint8Array(0);
    }
    if (parts.length === 1) {
      return parts[0];
    }
    let total = 0;
    for (let i = 0; i < parts.length; i++) {
      total += parts[i].length + 1;
    }
    const out = new Uint8Array(total);
    let at = 0;
    for (let i = 0; i < parts.length; i++) {
      out.set(parts[i], at);
      at += parts[i].length;
      out[at] = 0x0a;
      at++;
    }
    return out;
  }
}

/** 流解码结果：数据 + 未解码的图像过滤器名（没有则为空串） */
export class PdfStreamResult {
  readonly data: Uint8Array;
  /** 剩余的图像过滤器名，如 DCTDecode；空串表示已完全解码 */
  readonly imageFilter: string;
  /** 该图像过滤器对应的 DecodeParms */
  readonly imageParms: PdfObj;

  constructor(data: Uint8Array, imageFilter: string, imageParms: PdfObj) {
    this.data = data;
    this.imageFilter = imageFilter;
    this.imageParms = imageParms;
  }
}

/**
 * PDF 基础对象模型。
 *
 * PDF 的语法只有 8 种对象（null / 布尔 / 数字 / 字符串 / 名字 / 数组 / 字典 / 流）
 * 外加一个「间接引用」。ArkTS 不允许 any，也不方便用联合类型互相转换，
 * 因此这里用「带 kind 标记的单一类」承载所有对象，取值时用 asXxx() 系列方法，
 * 类型不匹配一律返回安全默认值（PDF 文件常有轻微不规范，取值处到处抛异常没法用）。
 */

/** 对象类型标记 */
export class PdfKind {
  static readonly NULL: number = 0;
  static readonly BOOL: number = 1;
  static readonly NUMBER: number = 2;
  /** 字符串，内容按字节保存（可能是二进制或 UTF-16BE） */
  static readonly STRING: number = 3;
  /** 名字对象，如 /Type，保存时不带斜杠 */
  static readonly NAME: number = 4;
  static readonly ARRAY: number = 5;
  static readonly DICT: number = 6;
  /** 流对象：字典 + 原始（未解码）数据 */
  static readonly STREAM: number = 7;
  /** 间接引用，如 12 0 R */
  static readonly REF: number = 8;
  /** 关键字/运算符，如 obj、stream、Tj，只在词法层出现 */
  static readonly KEYWORD: number = 9;
}

/**
 * 一个 PDF 对象。
 *
 * 各字段按 kind 取用，未使用的字段保持默认值：
 * NUMBER 用 num；BOOL 用 flag；NAME/KEYWORD 用 name；STRING 用 bytes；
 * ARRAY 用 items；DICT/STREAM 用 map（STREAM 另有 raw）；REF 用 refNum/refGen。
 */
export class PdfObj {
  readonly kind: number;
  num: number = 0;
  flag: boolean = false;
  name: string = '';
  bytes: Uint8Array | null = null;
  items: PdfObj[] | null = null;
  map: Map<string, PdfObj> | null = null;
  /** 流的原始字节（尚未按 Filter 解码） */
  raw: Uint8Array | null = null;
  refNum: number = 0;
  refGen: number = 0;

  constructor(kind: number) {
    this.kind = kind;
  }

  /** 全局共享的 null 对象（PDF 里 null 与「缺失」等价，可安全共享） */
  static readonly NULL_OBJ: PdfObj = new PdfObj(PdfKind.NULL);

  static ofBool(v: boolean): PdfObj {
    const o = new PdfObj(PdfKind.BOOL);
    o.flag = v;
    return o;
  }

  static ofNumber(v: number): PdfObj {
    const o = new PdfObj(PdfKind.NUMBER);
    o.num = v;
    return o;
  }

  static ofString(bytes: Uint8Array): PdfObj {
    const o = new PdfObj(PdfKind.STRING);
    o.bytes = bytes;
    return o;
  }

  static ofName(name: string): PdfObj {
    const o = new PdfObj(PdfKind.NAME);
    o.name = name;
    return o;
  }

  static ofKeyword(name: string): PdfObj {
    const o = new PdfObj(PdfKind.KEYWORD);
    o.name = name;
    return o;
  }

  static ofArray(items: PdfObj[]): PdfObj {
    const o = new PdfObj(PdfKind.ARRAY);
    o.items = items;
    return o;
  }

  static ofDict(map: Map<string, PdfObj>): PdfObj {
    const o = new PdfObj(PdfKind.DICT);
    o.map = map;
    return o;
  }

  /** 由字典升级成流对象（解析到 stream 关键字时调用） */
  static ofStream(map: Map<string, PdfObj>, raw: Uint8Array): PdfObj {
    const o = new PdfObj(PdfKind.STREAM);
    o.map = map;
    o.raw = raw;
    return o;
  }

  static ofRef(refNum: number, refGen: number): PdfObj {
    const o = new PdfObj(PdfKind.REF);
    o.refNum = refNum;
    o.refGen = refGen;
    return o;
  }

  isNull(): boolean {
    return this.kind === PdfKind.NULL;
  }

  isNumber(): boolean {
    return this.kind === PdfKind.NUMBER;
  }

  isName(): boolean {
    return this.kind === PdfKind.NAME;
  }

  isString(): boolean {
    return this.kind === PdfKind.STRING;
  }

  isArray(): boolean {
    return this.kind === PdfKind.ARRAY;
  }

  /** 流对象同时也是字典 */
  isDict(): boolean {
    return this.kind === PdfKind.DICT || this.kind === PdfKind.STREAM;
  }

  isStream(): boolean {
    return this.kind === PdfKind.STREAM;
  }

  isRef(): boolean {
    return this.kind === PdfKind.REF;
  }

  isKeyword(): boolean {
    return this.kind === PdfKind.KEYWORD;
  }

  /** 数字值，非数字返回 fallback */
  asNumber(fallback: number): number {
    return this.kind === PdfKind.NUMBER ? this.num : fallback;
  }

  /** 整数值（截断），非数字返回 fallback */
  asInt(fallback: number): number {
    return this.kind === PdfKind.NUMBER ? Math.trunc(this.num) : fallback;
  }

  /** 名字值，非名字返回空串 */
  asName(): string {
    return this.kind === PdfKind.NAME ? this.name : '';
  }

  asBool(fallback: boolean): boolean {
    return this.kind === PdfKind.BOOL ? this.flag : fallback;
  }

  /** 字符串字节，非字符串返回空数组 */
  asBytes(): Uint8Array {
    if (this.kind === PdfKind.STRING && this.bytes !== null) {
      return this.bytes;
    }
    return new Uint8Array(0);
  }

  /** 数组元素，非数组返回空数组 */
  asArray(): PdfObj[] {
    if (this.kind === PdfKind.ARRAY && this.items !== null) {
      return this.items;
    }
    return [];
  }

  /**
   * 取字典里某个键（不解引用）。
   * 缺失或本身不是字典时返回 NULL_OBJ，让调用方可以链式取值而不必判空。
   */
  get(key: string): PdfObj {
    if (this.map === null) {
      return PdfObj.NULL_OBJ;
    }
    const v = this.map.get(key);
    return v === undefined ? PdfObj.NULL_OBJ : v;
  }

  /** 字典里是否存在某键 */
  has(key: string): boolean {
    return this.map !== null && this.map.has(key);
  }

  /** 字典的全部键（用于遍历 Resources 之类的子字典） */
  keys(): string[] {
    const out: string[] = [];
    if (this.map === null) {
      return out;
    }
    this.map.forEach((value: PdfObj, key: string) => {
      out.push(key);
    });
    return out;
  }

  /** 往字典里写入（构造 PDF 时用） */
  set(key: string, value: PdfObj): void {
    if (this.map === null) {
      this.map = new Map<string, PdfObj>();
    }
    this.map.set(key, value);
  }
}

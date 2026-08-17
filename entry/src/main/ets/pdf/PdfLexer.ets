/**
 * PDF 词法/语法分析：把字节流切成 PdfObj。
 *
 * PDF 的语法非常小，但细节容易踩坑，这里都按 PDF 32000-1 第 7.2/7.3 节处理：
 *  - 空白：\0 \t \n \f \r 空格；注释 `%` 到行尾；
 *  - 数字：`1`、`-2.5`、`.5`、`4.`（不用 parseFloat，ArkTS 里自己解析更可控）；
 *  - 字符串：`(...)` 支持嵌套括号、\n \t 等转义、\ddd 八进制、行尾续行；
 *    `<...>` 十六进制串，奇数位补 0；
 *  - 名字：`/Name`，`#xx` 是十六进制转义；
 *  - 数组/字典：`[ ]`、`<< >>`；
 *  - 间接引用：`12 0 R` 需要向前看两个记号才能和数字区分开。
 *
 * 词法层把 `[`、`]`、`<<`、`>>` 也当关键字返回，由语法层组装成数组/字典；
 * 语法层同时负责识别 `R`（间接引用），因此需要一个记号回退栈。
 */

import { PdfKind, PdfObj } from './PdfObject';

export class PdfLexer {
  private readonly data: Uint8Array;
  /** 当前读取位置（公开，供内容流的内联图片等场景直接接管） */
  pos: number;
  /** 扫描上界 */
  readonly end: number;

  constructor(data: Uint8Array, start: number, end: number) {
    this.data = data;
    this.pos = start;
    this.end = end < data.length ? end : data.length;
  }

  /** 是否是 PDF 空白字符 */
  static isWhite(c: number): boolean {
    return c === 0x20 || c === 0x0a || c === 0x0d || c === 0x09 || c === 0x0c || c === 0x00;
  }

  /** 是否是 PDF 分隔符 */
  static isDelim(c: number): boolean {
    return c === 0x28 || c === 0x29 || c === 0x3c || c === 0x3e || c === 0x5b || c === 0x5d ||
      c === 0x7b || c === 0x7d || c === 0x2f || c === 0x25;
  }

  /** 普通字符（既不是空白也不是分隔符），名字与关键字由它们组成 */
  static isRegular(c: number): boolean {
    return !PdfLexer.isWhite(c) && !PdfLexer.isDelim(c);
  }

  /** 十六进制字符转数值，非法返回 -1 */
  static hexVal(c: number): number {
    if (c >= 0x30 && c <= 0x39) {
      return c - 0x30;
    }
    if (c >= 0x41 && c <= 0x46) {
      return c - 0x41 + 10;
    }
    if (c >= 0x61 && c <= 0x66) {
      return c - 0x61 + 10;
    }
    return -1;
  }

  /** 跳过空白与注释 */
  skipWhite(): void {
    while (this.pos < this.end) {
      const c = this.data[this.pos];
      if (PdfLexer.isWhite(c)) {
        this.pos++;
      } else if (c === 0x25) {
        // 注释：直到行尾
        while (this.pos < this.end && this.data[this.pos] !== 0x0a && this.data[this.pos] !== 0x0d) {
          this.pos++;
        }
      } else {
        return;
      }
    }
  }

  /** 是否已到末尾（会先跳过空白） */
  atEnd(): boolean {
    this.skipWhite();
    return this.pos >= this.end;
  }

  /**
   * 取下一个记号。
   * @returns 数字/字符串/名字/关键字对象；到末尾返回 null
   */
  nextToken(): PdfObj | null {
    this.skipWhite();
    if (this.pos >= this.end) {
      return null;
    }
    const c = this.data[this.pos];
    if (c === 0x2f) {
      return this.readName();
    }
    if (c === 0x28) {
      return this.readLiteralString();
    }
    if (c === 0x3c) {
      if (this.pos + 1 < this.end && this.data[this.pos + 1] === 0x3c) {
        this.pos += 2;
        return PdfObj.ofKeyword('<<');
      }
      return this.readHexString();
    }
    if (c === 0x3e) {
      if (this.pos + 1 < this.end && this.data[this.pos + 1] === 0x3e) {
        this.pos += 2;
        return PdfObj.ofKeyword('>>');
      }
      this.pos++; // 落单的 '>'，跳过
      return PdfObj.ofKeyword('>');
    }
    if (c === 0x5b) {
      this.pos++;
      return PdfObj.ofKeyword('[');
    }
    if (c === 0x5d) {
      this.pos++;
      return PdfObj.ofKeyword(']');
    }
    if (c === 0x7b) {
      this.pos++;
      return PdfObj.ofKeyword('{');
    }
    if (c === 0x7d) {
      this.pos++;
      return PdfObj.ofKeyword('}');
    }
    if (c === 0x29) {
      this.pos++; // 多余的右括号，容错跳过
      return PdfObj.ofKeyword(')');
    }
    if ((c >= 0x30 && c <= 0x39) || c === 0x2b || c === 0x2d || c === 0x2e) {
      return this.readNumber();
    }
    return this.readKeyword();
  }

  /** 读数字：手写十进制解析，兼容 `--5`、`4.`、`.5` 这类不规范写法 */
  private readNumber(): PdfObj {
    let sign = 1;
    let seenSign = false;
    let intPart = 0;
    let fracPart = 0;
    let fracScale = 1;
    let inFrac = false;
    while (this.pos < this.end) {
      const c = this.data[this.pos];
      if (c === 0x2b || c === 0x2d) {
        if (!seenSign) {
          seenSign = true;
          if (c === 0x2d) {
            sign = -1;
          }
        }
        this.pos++;
        continue;
      }
      if (c === 0x2e) {
        inFrac = true;
        this.pos++;
        continue;
      }
      if (c >= 0x30 && c <= 0x39) {
        if (inFrac) {
          fracScale *= 10;
          fracPart = fracPart * 10 + (c - 0x30);
        } else {
          intPart = intPart * 10 + (c - 0x30);
        }
        this.pos++;
        continue;
      }
      if (PdfLexer.isRegular(c)) {
        // 数字后跟了其他普通字符（不规范内容），一并吃掉避免死循环
        this.pos++;
        continue;
      }
      break;
    }
    return PdfObj.ofNumber(sign * (intPart + fracPart / fracScale));
  }

  /** 读名字：`/Name`，支持 `#xx` 十六进制转义 */
  private readName(): PdfObj {
    this.pos++; // 跳过 '/'
    let name = '';
    while (this.pos < this.end) {
      const c = this.data[this.pos];
      if (!PdfLexer.isRegular(c)) {
        break;
      }
      this.pos++;
      if (c === 0x23 && this.pos + 1 < this.end) {
        const h = PdfLexer.hexVal(this.data[this.pos]);
        const l = PdfLexer.hexVal(this.data[this.pos + 1]);
        if (h >= 0 && l >= 0) {
          name += String.fromCharCode(h * 16 + l);
          this.pos += 2;
          continue;
        }
      }
      name += String.fromCharCode(c);
    }
    return PdfObj.ofName(name);
  }

  /** 读关键字（true/false/null/obj/stream/R 以及内容流运算符） */
  private readKeyword(): PdfObj {
    let name = '';
    while (this.pos < this.end && PdfLexer.isRegular(this.data[this.pos])) {
      name += String.fromCharCode(this.data[this.pos]);
      this.pos++;
    }
    if (name.length === 0) {
      // 理论上不会发生；跳一个字节保证前进
      this.pos++;
      return PdfObj.ofKeyword('');
    }
    return PdfObj.ofKeyword(name);
  }

  /** 读 `(...)` 字符串 */
  private readLiteralString(): PdfObj {
    this.pos++; // 跳过 '('
    const out: number[] = [];
    let depth = 1;
    while (this.pos < this.end) {
      let c = this.data[this.pos];
      this.pos++;
      if (c === 0x5c) {
        // 转义序列
        if (this.pos >= this.end) {
          break;
        }
        c = this.data[this.pos];
        this.pos++;
        if (c === 0x6e) {
          out.push(0x0a);
        } else if (c === 0x72) {
          out.push(0x0d);
        } else if (c === 0x74) {
          out.push(0x09);
        } else if (c === 0x62) {
          out.push(0x08);
        } else if (c === 0x66) {
          out.push(0x0c);
        } else if (c >= 0x30 && c <= 0x37) {
          // 八进制，最多 3 位
          let v = c - 0x30;
          for (let k = 0; k < 2; k++) {
            if (this.pos < this.end) {
              const d = this.data[this.pos];
              if (d >= 0x30 && d <= 0x37) {
                v = v * 8 + (d - 0x30);
                this.pos++;
                continue;
              }
            }
            break;
          }
          out.push(v & 0xff);
        } else if (c === 0x0d) {
          // 行尾续行：\ 后面的换行不产生字符
          if (this.pos < this.end && this.data[this.pos] === 0x0a) {
            this.pos++;
          }
        } else if (c === 0x0a) {
          // 同上
        } else {
          out.push(c);
        }
        continue;
      }
      if (c === 0x28) {
        depth++;
        out.push(c);
        continue;
      }
      if (c === 0x29) {
        depth--;
        if (depth === 0) {
          break;
        }
        out.push(c);
        continue;
      }
      out.push(c);
    }
    return PdfObj.ofString(Uint8Array.from(out));
  }

  /** 读 `<...>` 十六进制字符串 */
  private readHexString(): PdfObj {
    this.pos++; // 跳过 '<'
    const out: number[] = [];
    let high = -1;
    while (this.pos < this.end) {
      const c = this.data[this.pos];
      this.pos++;
      if (c === 0x3e) {
        break;
      }
      const v = PdfLexer.hexVal(c);
      if (v < 0) {
        continue; // 空白与非法字符都忽略
      }
      if (high < 0) {
        high = v;
      } else {
        out.push(high * 16 + v);
        high = -1;
      }
    }
    if (high >= 0) {
      out.push(high * 16); // 奇数个十六进制位时末位补 0
    }
    return PdfObj.ofString(Uint8Array.from(out));
  }

  /** 从当前位置起跳过一个行尾（\r、\n 或 \r\n），stream 关键字后要用 */
  skipEol(): void {
    if (this.pos < this.end && this.data[this.pos] === 0x0d) {
      this.pos++;
    }
    if (this.pos < this.end && this.data[this.pos] === 0x0a) {
      this.pos++;
    }
  }
}

/**
 * 语法分析：在词法层之上组装数组、字典与间接引用。
 *
 * 间接引用要向前看两个记号（`12 0 R`），所以内部保留一个回退栈；
 * 遇到语法错误一律「尽量返回已解析的部分」，不抛异常——真实 PDF 里
 * 局部不规范太常见，整篇打不开的代价远大于少画一个元素。
 */
export class PdfParser {
  readonly lexer: PdfLexer;
  /** 记号回退栈（最多用到 2 个） */
  private pending: PdfObj[] = [];
  /** 回退栈非空时，这些记号在字节流中的起始位置（内联图片要用它精确定位） */
  private rewindPos: number = 0;

  constructor(lexer: PdfLexer) {
    this.lexer = lexer;
  }

  static fromBytes(data: Uint8Array, start: number, end: number): PdfParser {
    return new PdfParser(new PdfLexer(data, start, end));
  }

  /** 取下一个记号（先取回退栈） */
  private take(): PdfObj | null {
    if (this.pending.length > 0) {
      const v = this.pending[this.pending.length - 1];
      this.pending.pop();
      return v;
    }
    return this.lexer.nextToken();
  }

  private push(token: PdfObj): void {
    this.pending.push(token);
  }

  /** 回退栈是否为空（内联图片等需要直接操作 lexer.pos 时必须确认） */
  get buffered(): number {
    return this.pending.length;
  }

  /**
   * 解析一个完整对象（数组/字典会递归解析）。
   * @returns 对象；到末尾返回 null。关键字（含运算符）也会作为 KEYWORD 对象返回。
   */
  parseObject(): PdfObj | null {
    const token = this.take();
    if (token === null) {
      return null;
    }
    if (token.kind === PdfKind.NUMBER) {
      return this.maybeRef(token);
    }
    if (token.kind !== PdfKind.KEYWORD) {
      return token;
    }
    const kw = token.name;
    if (kw === '[') {
      return this.parseArray();
    }
    if (kw === '<<') {
      return this.parseDict();
    }
    if (kw === 'true') {
      return PdfObj.ofBool(true);
    }
    if (kw === 'false') {
      return PdfObj.ofBool(false);
    }
    if (kw === 'null') {
      return PdfObj.NULL_OBJ;
    }
    return token;
  }

  /**
   * 已消费到的字节位置。
   * 回退栈非空时返回「回退记号的起始位置」，因此内联图片可以据此接管字节流。
   */
  position(): number {
    return this.pending.length === 0 ? this.lexer.pos : this.rewindPos;
  }

  /** 数字之后可能是间接引用（`n g R`），要向前看两个记号 */
  private maybeRef(first: PdfObj): PdfObj {
    const lookaheadStart = this.lexer.pos;
    const second = this.take();
    if (second === null) {
      return first;
    }
    if (second.kind !== PdfKind.NUMBER) {
      this.rewindPos = lookaheadStart;
      this.push(second);
      return first;
    }
    const third = this.take();
    if (third === null) {
      this.rewindPos = lookaheadStart;
      this.push(second);
      return first;
    }
    if (third.kind === PdfKind.KEYWORD && third.name === 'R') {
      return PdfObj.ofRef(Math.trunc(first.num), Math.trunc(second.num));
    }
    // 不是引用：把两个记号按逆序压回
    this.rewindPos = lookaheadStart;
    this.push(third);
    this.push(second);
    return first;
  }

  private parseArray(): PdfObj {
    const items: PdfObj[] = [];
    while (true) {
      const token = this.take();
      if (token === null) {
        break;
      }
      if (token.kind === PdfKind.KEYWORD) {
        const kw = token.name;
        if (kw === ']') {
          break;
        }
        if (kw === '>>' || kw === 'endobj' || kw === 'stream') {
          // 数组没闭合就遇到了外层结束标记，回退给上层处理
          this.push(token);
          break;
        }
      }
      this.push(token);
      const value = this.parseObject();
      if (value === null) {
        break;
      }
      if (value.kind === PdfKind.KEYWORD) {
        continue; // 数组里的杂散关键字直接丢弃
      }
      items.push(value);
    }
    return PdfObj.ofArray(items);
  }

  private parseDict(): PdfObj {
    const map = new Map<string, PdfObj>();
    while (true) {
      const token = this.take();
      if (token === null) {
        break;
      }
      if (token.kind === PdfKind.KEYWORD) {
        const kw = token.name;
        if (kw === '>>') {
          break;
        }
        if (kw === 'endobj' || kw === 'stream') {
          this.push(token);
          break;
        }
        continue; // 键位置上的杂散关键字丢弃
      }
      if (token.kind !== PdfKind.NAME) {
        continue; // 键必须是名字，其他内容跳过
      }
      const value = this.parseObject();
      if (value === null) {
        break;
      }
      if (value.kind === PdfKind.KEYWORD) {
        const kw = value.name;
        if (kw === '>>' || kw === 'endobj' || kw === 'stream') {
          this.push(value);
          break;
        }
        continue;
      }
      map.set(token.name, value);
    }
    return PdfObj.ofDict(map);
  }

  /**
   * 取走下一个记号，要求它是关键字。
   * @returns 关键字名；不是关键字则把记号回退并返回空串
   */
  nextKeyword(): string {
    const token = this.take();
    if (token === null) {
      return '';
    }
    if (token.kind === PdfKind.KEYWORD) {
      return token.name;
    }
    this.push(token);
    return '';
  }
}

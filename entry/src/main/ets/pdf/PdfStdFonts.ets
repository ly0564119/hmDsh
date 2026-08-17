/**
 * 标准 14 字体表的运行时访问层。
 *
 * PdfStdMetrics 里的表是空格分隔的字符串（源码体积小），这里按需解析成 Map 并缓存；
 * 一份文档通常只会用到两三种编码，惰性解析比启动时全解析划算。
 *
 * 对外提供三件事：
 *  1. 编码表：码位 → 字形名（Standard / WinAnsi / MacRoman / Symbol / ZapfDingbats）；
 *  2. 字形名 → Unicode（含 uniXXXX、uXXXX 这类程序化命名的解析）；
 *  3. 标准 14 字体的字宽（没有内嵌 Widths 数组时用它兜底）。
 */

import { PdfStdData } from './PdfStdMetrics';

/** 标准字体族标识，同时用于挑选字宽表 */
export class PdfStdFamily {
  static readonly HELVETICA: number = 0;
  static readonly TIMES: number = 1;
  static readonly COURIER: number = 2;
  static readonly SYMBOL: number = 3;
  static readonly ZAPF: number = 4;
}

export class PdfStdFonts {
  /** 编码名 → 码位表（256 项，未定义处为空串） */
  private static encCache: Map<string, string[]> = new Map<string, string[]>();
  /** 字形名 → Unicode */
  private static glyphCache: Map<string, number> | null = null;
  /** 字体名 → （字形名 → 宽度） */
  private static widthCache: Map<string, Map<string, number>> = new Map<string, Map<string, number>>();

  /** 把 `-` 视为未定义，解析成 256 项的码位表 */
  private static parseEncoding(source: string): string[] {
    const parts = source.split(' ');
    const table: string[] = [];
    for (let i = 0; i < 256; i++) {
      const name = i < parts.length ? parts[i] : '-';
      table.push(name === '-' ? '' : name);
    }
    return table;
  }

  /**
   * 取某个基础编码的码位表。
   * @param name WinAnsiEncoding / MacRomanEncoding / StandardEncoding / Symbol / ZapfDingbats
   */
  static encoding(name: string): string[] {
    const cached = PdfStdFonts.encCache.get(name);
    if (cached !== undefined) {
      return cached;
    }
    let source = PdfStdData.ENC_STANDARD;
    if (name === 'WinAnsiEncoding') {
      source = PdfStdData.ENC_WINANSI;
    } else if (name === 'MacRomanEncoding') {
      source = PdfStdData.ENC_MACROMAN;
    } else if (name === 'Symbol') {
      source = PdfStdData.ENC_SYMBOL;
    } else if (name === 'ZapfDingbats') {
      source = PdfStdData.ENC_ZAPF;
    }
    const table = PdfStdFonts.parseEncoding(source);
    PdfStdFonts.encCache.set(name, table);
    return table;
  }

  /** 字形名 → Unicode 表（Adobe Glyph List 子集） */
  private static glyphTable(): Map<string, number> {
    if (PdfStdFonts.glyphCache !== null) {
      return PdfStdFonts.glyphCache;
    }
    const map = new Map<string, number>();
    const parts = PdfStdData.GLYPH_UNICODE.split(' ');
    for (let i = 0; i + 1 < parts.length; i += 2) {
      map.set(parts[i], PdfStdFonts.parseInt(parts[i + 1]));
    }
    PdfStdFonts.glyphCache = map;
    return map;
  }

  /** 十进制整数解析（ArkTS 里避免依赖 parseInt 的宽松行为） */
  private static parseInt(text: string): number {
    let v = 0;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if (c < 0x30 || c > 0x39) {
        return v;
      }
      v = v * 10 + (c - 0x30);
    }
    return v;
  }

  /** 十六进制整数解析，失败返回 -1 */
  private static parseHex(text: string): number {
    if (text.length === 0) {
      return -1;
    }
    let v = 0;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      let d = -1;
      if (c >= 0x30 && c <= 0x39) {
        d = c - 0x30;
      } else if (c >= 0x41 && c <= 0x46) {
        d = c - 0x41 + 10;
      } else if (c >= 0x61 && c <= 0x66) {
        d = c - 0x61 + 10;
      } else {
        return -1;
      }
      v = v * 16 + d;
    }
    return v;
  }

  /**
   * 字形名 → Unicode 码点。
   *
   * 除了查 AGL，还要处理三类程序化命名（内嵌子集字体里很常见）：
   *  - `uni4E2D`：4 位十六进制 Unicode；
   *  - `u4E2D` / `u1F600`：4~6 位十六进制；
   *  - `gXX` / `cidXX` / `indexXX`：只是字形序号，没有语义，返回 -1。
   * 另外 `Aacute.sc`、`f_i` 这种带后缀/连字的名字，取第一段再查。
   *
   * @returns Unicode 码点，无法确定返回 -1
   */
  static glyphUnicode(name: string): number {
    if (name.length === 0) {
      return -1;
    }
    const table = PdfStdFonts.glyphTable();
    const direct = table.get(name);
    if (direct !== undefined) {
      return direct;
    }
    if (name.startsWith('uni') && name.length >= 7) {
      const v = PdfStdFonts.parseHex(name.substring(3, 7));
      if (v >= 0) {
        return v;
      }
    }
    if (name.startsWith('u') && name.length >= 5 && name.length <= 7) {
      const v = PdfStdFonts.parseHex(name.substring(1));
      if (v >= 0) {
        return v;
      }
    }
    const dot = name.indexOf('.');
    if (dot > 0) {
      return PdfStdFonts.glyphUnicode(name.substring(0, dot));
    }
    const underscore = name.indexOf('_');
    if (underscore > 0) {
      return PdfStdFonts.glyphUnicode(name.substring(0, underscore));
    }
    return -1;
  }

  /**
   * 归一化字体名 → 标准字体族 + 粗斜体判断。
   *
   * 内嵌字体的 BaseFont 常带子集前缀（`ABCDEF+Arial-BoldMT`），
   * 这里先去掉前缀，再按关键字猜族与样式，用于选字宽表和渲染时的粗/斜体。
   */
  static normalizeBaseFont(baseFont: string): string {
    let name = baseFont;
    if (name.length > 7 && name.charAt(6) === '+') {
      name = name.substring(7);
    }
    return name;
  }

  /** 由字体名判断标准字体族 */
  static familyOf(baseFont: string): number {
    const lower = PdfStdFonts.normalizeBaseFont(baseFont).toLowerCase();
    if (lower.indexOf('courier') >= 0 || lower.indexOf('mono') >= 0) {
      return PdfStdFamily.COURIER;
    }
    if (lower.indexOf('zapf') >= 0 || lower.indexOf('dingbat') >= 0) {
      return PdfStdFamily.ZAPF;
    }
    if (lower.indexOf('symbol') >= 0) {
      return PdfStdFamily.SYMBOL;
    }
    if (lower.indexOf('times') >= 0 || lower.indexOf('serif') >= 0 ||
      lower.indexOf('georgia') >= 0 || lower.indexOf('roman') >= 0 ||
      lower.indexOf('song') >= 0 || lower.indexOf('ming') >= 0 ||
      lower.indexOf('book') >= 0) {
      return PdfStdFamily.TIMES;
    }
    return PdfStdFamily.HELVETICA;
  }

  /** 由字体名判断是否粗体 */
  static boldByName(baseFont: string): boolean {
    const lower = PdfStdFonts.normalizeBaseFont(baseFont).toLowerCase();
    return lower.indexOf('bold') >= 0 || lower.indexOf('black') >= 0 ||
      lower.indexOf('heavy') >= 0 || lower.indexOf('semibold') >= 0;
  }

  /** 由字体名判断是否斜体 */
  static italicByName(baseFont: string): boolean {
    const lower = PdfStdFonts.normalizeBaseFont(baseFont).toLowerCase();
    return lower.indexOf('italic') >= 0 || lower.indexOf('oblique') >= 0;
  }

  /** 标准字体的内置编码：Symbol / ZapfDingbats 用自己的，其余用 Standard */
  static builtinEncodingName(family: number): string {
    if (family === PdfStdFamily.SYMBOL) {
      return 'Symbol';
    }
    if (family === PdfStdFamily.ZAPF) {
      return 'ZapfDingbats';
    }
    return 'StandardEncoding';
  }

  /** 取某个标准字体的字宽表（key 由 family + 粗斜体决定） */
  private static widthTable(family: number, bold: boolean, italic: boolean): Map<string, number> | null {
    if (family === PdfStdFamily.COURIER) {
      return null; // 等宽，走常量
    }
    let key = 'Helvetica';
    let source = PdfStdData.W_HELVETICA;
    if (family === PdfStdFamily.SYMBOL) {
      key = 'Symbol';
      source = PdfStdData.W_SYMBOL;
    } else if (family === PdfStdFamily.ZAPF) {
      key = 'ZapfDingbats';
      source = PdfStdData.W_ZAPF;
    } else if (family === PdfStdFamily.TIMES) {
      if (bold && italic) {
        key = 'Times-BoldItalic';
        source = PdfStdData.W_TIMES_BOLD_ITALIC;
      } else if (bold) {
        key = 'Times-Bold';
        source = PdfStdData.W_TIMES_BOLD;
      } else if (italic) {
        key = 'Times-Italic';
        source = PdfStdData.W_TIMES_ITALIC;
      } else {
        key = 'Times-Roman';
        source = PdfStdData.W_TIMES;
      }
    } else {
      if (bold && italic) {
        key = 'Helvetica-BoldOblique';
        source = PdfStdData.W_HELVETICA_BOLD_OBLIQUE;
      } else if (bold) {
        key = 'Helvetica-Bold';
        source = PdfStdData.W_HELVETICA_BOLD;
      } else if (italic) {
        key = 'Helvetica-Oblique';
        source = PdfStdData.W_HELVETICA_OBLIQUE;
      }
    }
    const cached = PdfStdFonts.widthCache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const map = new Map<string, number>();
    const parts = source.split(' ');
    for (let i = 0; i + 1 < parts.length; i += 2) {
      map.set(parts[i], PdfStdFonts.parseInt(parts[i + 1]));
    }
    PdfStdFonts.widthCache.set(key, map);
    return map;
  }

  /**
   * 按字形名取标准字体宽度（单位 1/1000 em）。
   * @returns 宽度；表里没有该字形返回 -1
   */
  static glyphWidth(family: number, bold: boolean, italic: boolean, glyphName: string): number {
    if (family === PdfStdFamily.COURIER) {
      return PdfStdData.COURIER_WIDTH;
    }
    const table = PdfStdFonts.widthTable(family, bold, italic);
    if (table === null) {
      return PdfStdData.COURIER_WIDTH;
    }
    const w = table.get(glyphName);
    return w === undefined ? -1 : w;
  }

  /**
   * 按 Unicode 估算宽度：标准表里查不到字形名时的兜底。
   * 中日韩与全角标点按 1000（全角），其余按 500。
   */
  static estimateWidth(unicode: number): number {
    if (unicode < 0) {
      return 500;
    }
    if ((unicode >= 0x1100 && unicode <= 0x115f) || (unicode >= 0x2e80 && unicode <= 0xa4cf) ||
      (unicode >= 0xac00 && unicode <= 0xd7a3) || (unicode >= 0xf900 && unicode <= 0xfaff) ||
      (unicode >= 0xfe30 && unicode <= 0xfe6f) || (unicode >= 0xff00 && unicode <= 0xff60) ||
      (unicode >= 0xffe0 && unicode <= 0xffe6) || (unicode >= 0x20000 && unicode <= 0x3fffd)) {
      return 1000;
    }
    return 500;
  }
}

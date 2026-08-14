/**
 * Office 文档解析：.docx 提取纯文本、.xlsx 提取表格网格。
 * 基于 ZIP + XML 的手工解析，不依赖第三方库。
 */

import { ZipReader } from '../common/ZipReader';

export class XlsxSheet {
  rows: string[][] = [];
  maxCols: number = 0;
  maxRows: number = 0;
}

export class OfficeParser {

  static decodeEntities(s: string): string {
    return s.split('&amp;').join('&')
      .split('&lt;').join('<')
      .split('&gt;').join('>')
      .split('&quot;').join('"')
      .split('&apos;').join("'")
      .split('&#10;').join('\n')
      .split('&#13;').join('\r');
  }

  /** 取标签属性值，如 attr('<c r="A1">', 'r') -> 'A1' */
  private static attr(tag: string, name: string): string {
    const key = name + '="';
    const idx = tag.indexOf(key);
    if (idx < 0) {
      return '';
    }
    const start = idx + key.length;
    const end = tag.indexOf('"', start);
    if (end < 0) {
      return '';
    }
    return tag.substring(start, end);
  }

  /** 取块内某简单标签的文本，如 innerTag('<c><v>12</v></c>', 'v') -> '12' */
  private static innerTag(block: string, tag: string): string {
    const open = block.indexOf('<' + tag + '>');
    const open2 = block.indexOf('<' + tag + ' ');
    let o = -1;
    if (open < 0) {
      o = open2;
    } else if (open2 < 0) {
      o = open;
    } else {
      o = Math.min(open, open2);
    }
    if (o < 0) {
      return '';
    }
    const gt = block.indexOf('>', o);
    const close = block.indexOf('</' + tag + '>', o);
    if (gt < 0 || close < 0) {
      return '';
    }
    return block.substring(gt + 1, close);
  }

  /** 单元格引用转列号（0 基），"A1"->0，"B2"->1，"AA1"->26 */
  static colIndex(ref: string): number {
    let col = 0;
    for (let i = 0; i < ref.length; i++) {
      const c = ref.charCodeAt(i);
      if (c >= 65 && c <= 90) {
        col = col * 26 + (c - 65 + 1);
      } else {
        break;
      }
    }
    return col - 1;
  }

  /** .docx 的 document.xml 提取纯文本 */
  static docxToText(xml: string): string {
    let out = '';
    let i = 0;
    while (i < xml.length) {
      const lt = xml.indexOf('<', i);
      if (lt < 0) {
        break;
      }
      if (xml.startsWith('</w:p>', lt)) {
        out += '\n';
        i = lt + 6;
        continue;
      }
      if (xml.startsWith('<w:tab', lt)) {
        out += '\t';
        const gt = xml.indexOf('>', lt);
        i = gt < 0 ? lt + 1 : gt + 1;
        continue;
      }
      if (xml.startsWith('<w:br', lt)) {
        out += '\n';
        const gt = xml.indexOf('>', lt);
        i = gt < 0 ? lt + 1 : gt + 1;
        continue;
      }
      if (xml.startsWith('<w:t>', lt) || xml.startsWith('<w:t ', lt)) {
        const gt = xml.indexOf('>', lt);
        const end = xml.indexOf('</w:t>', lt);
        if (gt >= 0 && end >= 0 && end > gt) {
          out += xml.substring(gt + 1, end);
          i = end + 6;
          continue;
        }
      }
      const gt = xml.indexOf('>', lt);
      i = gt < 0 ? lt + 1 : gt + 1;
    }
    return OfficeParser.decodeEntities(out);
  }

  /** 解析 sharedStrings.xml -> 字符串数组 */
  static parseSharedStrings(xml: string): string[] {
    const arr: string[] = [];
    let i = 0;
    while (true) {
      const si1 = xml.indexOf('<si>', i);
      const si2 = xml.indexOf('<si ', i);
      let start = -1;
      if (si1 < 0) {
        start = si2;
      } else if (si2 < 0) {
        start = si1;
      } else {
        start = Math.min(si1, si2);
      }
      if (start < 0) {
        break;
      }
      const siEnd = xml.indexOf('</si>', start);
      if (siEnd < 0) {
        break;
      }
      const block = xml.substring(start, siEnd);
      let text = '';
      let j = 0;
      while (true) {
        const t1 = block.indexOf('<t>', j);
        const t2 = block.indexOf('<t ', j);
        let tt = -1;
        if (t1 < 0) {
          tt = t2;
        } else if (t2 < 0) {
          tt = t1;
        } else {
          tt = Math.min(t1, t2);
        }
        if (tt < 0) {
          break;
        }
        const gt = block.indexOf('>', tt);
        const te = block.indexOf('</t>', tt);
        if (gt < 0 || te < 0) {
          break;
        }
        text += block.substring(gt + 1, te);
        j = te + 4;
      }
      arr.push(OfficeParser.decodeEntities(text));
      i = siEnd + 5;
    }
    return arr;
  }

  /** 解析一行 <row>...</row> 内的单元格 */
  private static parseRow(rowBlock: string, shared: string[]): string[] {
    const cells: string[] = [];
    let i = 0;
    while (i < rowBlock.length) {
      const cs = rowBlock.indexOf('<c', i);
      if (cs < 0) {
        break;
      }
      if (rowBlock.charAt(cs + 2) === '/') {
        i = cs + 3;
        continue;
      }
      const ce = rowBlock.indexOf('</c>', cs);
      if (ce < 0) {
        break;
      }
      const openEnd = rowBlock.indexOf('>', cs);
      if (openEnd < 0) {
        break;
      }
      const openTag = rowBlock.substring(cs, openEnd + 1);
      const cellBlock = rowBlock.substring(cs, ce);
      const r = OfficeParser.attr(openTag, 'r');
      const t = OfficeParser.attr(openTag, 't');
      let text = '';
      if (t === 'inlineStr') {
        text = OfficeParser.innerTag(cellBlock, 't');
      } else {
        const v = OfficeParser.innerTag(cellBlock, 'v');
        if (t === 's') {
          const idx = OfficeParser.toInt(v);
          if (idx >= 0 && idx < shared.length) {
            text = shared[idx];
          } else {
            text = v;
          }
        } else {
          text = v;
        }
      }
      text = OfficeParser.decodeEntities(text);
      const col = OfficeParser.colIndex(r);
      while (cells.length <= col) {
        cells.push('');
      }
      cells[col] = text;
      i = ce + 4;
    }
    return cells;
  }

  /** 解析 sheet1.xml -> 表格网格 */
  static parseSheet(sheetXml: string, shared: string[]): XlsxSheet {
    const sheet = new XlsxSheet();
    const rows: string[][] = [];
    let i = 0;
    while (true) {
      const rs = sheetXml.indexOf('<row', i);
      if (rs < 0) {
        break;
      }
      const rgt = sheetXml.indexOf('>', rs);
      const re = sheetXml.indexOf('</row>', rs);
      if (rgt < 0 || re < 0) {
        break;
      }
      const rowBlock = sheetXml.substring(rgt + 1, re);
      rows.push(OfficeParser.parseRow(rowBlock, shared));
      i = re + 6;
    }
    let maxCols = 0;
    for (let r = 0; r < rows.length; r++) {
      if (rows[r].length > maxCols) {
        maxCols = rows[r].length;
      }
    }
    sheet.rows = rows;
    sheet.maxCols = maxCols;
    sheet.maxRows = rows.length;
    return sheet;
  }

  private static toInt(s: string): number {
    if (s.length === 0) {
      return -1;
    }
    let n = 0;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c >= 48 && c <= 57) {
        n = n * 10 + (c - 48);
      } else {
        return -1;
      }
    }
    return n;
  }
}

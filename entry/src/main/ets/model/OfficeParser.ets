/**
 * Office 文档解析：.docx 提取纯文本、.xlsx 提取表格网格。
 * 基于内存 ZIP + 手写 XML 扫描，不依赖第三方库。
 *
 * 保真度说明：docx 只取文字（丢样式/图片/复杂版式），xlsx 只取单元格文本。
 */

import { ZipArchive } from '../common/ZipReader';

/** xlsx 单个工作表的内容 */
export class XlsxSheet {
  rows: string[][] = [];
  maxCols: number = 0;
  maxRows: number = 0;
}

export class OfficeParser {
  /** docx 正文部件路径 */
  private static readonly DOCX_BODY: string = 'word/document.xml';

  /** XML 实体还原 */
  static decodeEntities(s: string): string {
    if (s.indexOf('&') < 0) {
      return s;
    }
    return s.split('&lt;').join('<')
      .split('&gt;').join('>')
      .split('&quot;').join('"')
      .split('&apos;').join("'")
      .split('&#10;').join('\n')
      .split('&#13;').join('\r')
      .split('&#9;').join('\t')
      .split('&amp;').join('&');
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
      } else if (c >= 97 && c <= 122) {
        col = col * 26 + (c - 97 + 1);
      } else {
        break;
      }
    }
    return col - 1;
  }

  /** 单元格引用取行号（1 基），"B12"->12；取不到返回 0 */
  private static rowIndex(ref: string): number {
    let row = 0;
    let seen = false;
    for (let i = 0; i < ref.length; i++) {
      const c = ref.charCodeAt(i);
      if (c >= 48 && c <= 57) {
        row = row * 10 + (c - 48);
        seen = true;
      } else if (seen) {
        break;
      }
    }
    return row;
  }

  /** 从 docx 包里提取正文纯文本 */
  static docxToText(archive: ZipArchive): string {
    let path = OfficeParser.DOCX_BODY;
    if (!archive.has(path)) {
      // 个别工具导出的 docx 正文名字不同，兜底找一个
      path = archive.findByPrefixSuffix('word/document', '.xml');
      if (path.length === 0) {
        throw new Error('这不是标准 .docx（缺少 word/document.xml），请用 Word 另存为 .docx');
      }
    }
    return OfficeParser.parseDocumentXml(archive.readText(path));
  }

  /**
   * 解析 word/document.xml 的正文文字。
   *
   * 规则：<w:t> 取文字；段落结束换行；<w:br>/<w:cr> 换行；<w:tab> 制表符。
   * 表格特殊处理：单元格之间用制表符分隔、整行结束才换行，
   * 否则每个单元格都会各占一行，表格会被拉得很长。
   */
  static parseDocumentXml(xml: string): string {
    let out = '';
    let i = 0;
    // 是否正处于表格单元格内（决定段落结束是换行还是不换行）
    let inCell = false;
    while (i < xml.length) {
      const lt = xml.indexOf('<', i);
      if (lt < 0) {
        break;
      }
      if (xml.startsWith('<w:tc>', lt) || xml.startsWith('<w:tc ', lt)) {
        inCell = true;
        i = OfficeParser.skipTag(xml, lt);
        continue;
      }
      if (xml.startsWith('</w:tc>', lt)) {
        // 单元格之间用制表符分隔
        inCell = false;
        out += '\t';
        i = lt + 7;
        continue;
      }
      if (xml.startsWith('</w:tr>', lt)) {
        out += '\n';
        i = lt + 7;
        continue;
      }
      if (xml.startsWith('</w:p>', lt)) {
        if (!inCell) {
          out += '\n';
        }
        i = lt + 6;
        continue;
      }
      if (xml.startsWith('<w:p/>', lt)) {
        // 自闭合的空段落也算一个空行
        if (!inCell) {
          out += '\n';
        }
        i = lt + 6;
        continue;
      }
      if (xml.startsWith('<w:tab', lt)) {
        out += '\t';
        i = OfficeParser.skipTag(xml, lt);
        continue;
      }
      if (xml.startsWith('<w:br', lt) || xml.startsWith('<w:cr', lt)) {
        out += '\n';
        i = OfficeParser.skipTag(xml, lt);
        continue;
      }
      if (xml.startsWith('<w:t>', lt) || xml.startsWith('<w:t ', lt)) {
        const gt = xml.indexOf('>', lt);
        const end = xml.indexOf('</w:t>', lt);
        if (gt >= 0 && end >= 0 && end > gt) {
          out += OfficeParser.decodeEntities(xml.substring(gt + 1, end));
          i = end + 6;
          continue;
        }
      }
      i = OfficeParser.skipTag(xml, lt);
    }
    return OfficeParser.normalizeLines(out);
  }

  /** 跳过 lt 处的这个标签，返回标签后的位置 */
  private static skipTag(xml: string, lt: number): number {
    const gt = xml.indexOf('>', lt);
    return gt < 0 ? lt + 1 : gt + 1;
  }

  /** 去掉行尾多余的制表符、连续空行压成一个、去掉首尾空行 */
  private static normalizeLines(text: string): string {
    const lines = text.split('\n');
    const kept: string[] = [];
    let blankRun = 0;
    for (let i = 0; i < lines.length; i++) {
      let line = lines[i];
      while (line.endsWith('\t')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.trim().length === 0) {
        blankRun++;
        if (blankRun > 1 || kept.length === 0) {
          continue; // 连续空行只留一个，开头的空行直接丢掉
        }
      } else {
        blankRun = 0;
      }
      kept.push(line);
    }
    while (kept.length > 0 && kept[kept.length - 1].trim().length === 0) {
      kept.pop();
    }
    return kept.join('\n');
  }

  /** 从 xlsx 包里提取第一个工作表 */
  static xlsxToSheet(archive: ZipArchive): XlsxSheet {
    let shared: string[] = [];
    if (archive.has('xl/sharedStrings.xml')) {
      shared = OfficeParser.parseSharedStrings(archive.readText('xl/sharedStrings.xml'));
    }
    let sheetPath = 'xl/worksheets/sheet1.xml';
    if (!archive.has(sheetPath)) {
      sheetPath = archive.findByPrefixSuffix('xl/worksheets/', '.xml');
      if (sheetPath.length === 0) {
        throw new Error('这不是标准 .xlsx（缺少工作表），请用 Excel 另存为 .xlsx');
      }
    }
    return OfficeParser.parseSheet(archive.readText(sheetPath), shared);
  }

  /** 解析 sharedStrings.xml -> 字符串数组 */
  static parseSharedStrings(xml: string): string[] {
    const arr: string[] = [];
    let i = 0;
    while (true) {
      const start = OfficeParser.indexOfTag(xml, 'si', i);
      if (start < 0) {
        break;
      }
      const siEnd = xml.indexOf('</si>', start);
      if (siEnd < 0) {
        break;
      }
      const block = xml.substring(start, siEnd);
      // 一个 <si> 里可能有多段 <t>（富文本 run），要全部拼起来
      let text = '';
      let j = 0;
      while (true) {
        const tt = OfficeParser.indexOfTag(block, 't', j);
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

  /** 找 `<tag>` 或 `<tag ` 中更靠前的那个 */
  private static indexOfTag(xml: string, tag: string, from: number): number {
    const a = xml.indexOf('<' + tag + '>', from);
    const b = xml.indexOf('<' + tag + ' ', from);
    if (a < 0) {
      return b;
    }
    if (b < 0) {
      return a;
    }
    return Math.min(a, b);
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
      const nextChar = rowBlock.charAt(cs + 2);
      if (nextChar !== ' ' && nextChar !== '>' && nextChar !== '/') {
        // 形如 <cols> 之类的其他标签，跳过
        i = cs + 2;
        continue;
      }
      const openEnd = rowBlock.indexOf('>', cs);
      if (openEnd < 0) {
        break;
      }
      const openTag = rowBlock.substring(cs, openEnd + 1);
      const r = OfficeParser.attr(openTag, 'r');
      const t = OfficeParser.attr(openTag, 't');
      let text = '';
      let next = openEnd + 1;
      if (!openTag.endsWith('/>')) {
        // 非自闭合单元格才有内容
        const ce = rowBlock.indexOf('</c>', cs);
        if (ce < 0) {
          break;
        }
        const cellBlock = rowBlock.substring(cs, ce);
        if (t === 'inlineStr') {
          text = OfficeParser.innerTag(cellBlock, 't');
        } else if (t === 's') {
          const idx = OfficeParser.toInt(OfficeParser.innerTag(cellBlock, 'v'));
          text = (idx >= 0 && idx < shared.length) ? shared[idx] : '';
        } else if (t === 'str') {
          text = OfficeParser.innerTag(cellBlock, 'v');
        } else {
          text = OfficeParser.innerTag(cellBlock, 'v');
        }
        next = ce + 4;
      }
      text = OfficeParser.decodeEntities(text);
      const col = OfficeParser.colIndex(r);
      const target = col >= 0 ? col : cells.length;
      while (cells.length <= target) {
        cells.push('');
      }
      cells[target] = text;
      i = next;
    }
    return cells;
  }

  /** 解析 sheetN.xml -> 表格网格（按 r 属性保留空行位置） */
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
      if (rgt < 0) {
        break;
      }
      const openTag = sheetXml.substring(rs, rgt + 1);
      const rowNo = OfficeParser.rowIndex(OfficeParser.attr(openTag, 'r'));
      if (openTag.endsWith('/>')) {
        // 空行
        if (rowNo > 0) {
          while (rows.length < rowNo) {
            rows.push([]);
          }
        } else {
          rows.push([]);
        }
        i = rgt + 1;
        continue;
      }
      const re = sheetXml.indexOf('</row>', rs);
      if (re < 0) {
        break;
      }
      const cells = OfficeParser.parseRow(sheetXml.substring(rgt + 1, re), shared);
      if (rowNo > 0) {
        while (rows.length < rowNo - 1) {
          rows.push([]);
        }
        if (rows.length === rowNo - 1) {
          rows.push(cells);
        } else {
          rows[rowNo - 1] = cells;
        }
      } else {
        rows.push(cells);
      }
      i = re + 6;
    }

    // 去掉尾部的空行
    while (rows.length > 0 && rows[rows.length - 1].length === 0) {
      rows.pop();
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

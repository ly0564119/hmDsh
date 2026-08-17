#!/usr/bin/env python3
"""生成 entry/src/main/ets/pdf/PdfStdMetrics.ets（PDF 标准 14 字体度量与编码表）。

数据来源都是公开标准，不是手抄的：
  * 字宽：reportlab 内置的 Adobe AFM 度量（reportlab.pdfbase._fontdata.widthsByFontGlyph）；
  * 编码表（码位 → 字形名）：reportlab.pdfbase._fontdata.encodings，
    对应 PDF 32000-1 附录 D 的 Standard / WinAnsi / MacRoman / Symbol / ZapfDingbats；
  * 字形名 → Unicode：Adobe Glyph List（fontTools.agl.AGL2UV）。

用法（需要 pip install reportlab fonttools）：
    python3 tools/gen/gen_pdf_metrics.py
"""

import os
from reportlab.pdfbase import _fontdata
from fontTools.agl import AGL2UV

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   '..', '..', 'entry', 'src', 'main', 'ets', 'pdf', 'PdfStdMetrics.ets')

ENCODINGS = [
    ('STANDARD', 'StandardEncoding'),
    ('WINANSI', 'WinAnsiEncoding'),
    ('MACROMAN', 'MacRomanEncoding'),
    ('SYMBOL', 'SymbolEncoding'),
    ('ZAPF', 'ZapfDingbatsEncoding'),
]

# 需要字宽表的字体（Courier 系列全部字形都是 600，用规则代替表）
WIDTH_FONTS = [
    ('HELVETICA', 'Helvetica'),
    ('HELVETICA_BOLD', 'Helvetica-Bold'),
    ('HELVETICA_OBLIQUE', 'Helvetica-Oblique'),
    ('HELVETICA_BOLD_OBLIQUE', 'Helvetica-BoldOblique'),
    ('TIMES', 'Times-Roman'),
    ('TIMES_BOLD', 'Times-Bold'),
    ('TIMES_ITALIC', 'Times-Italic'),
    ('TIMES_BOLD_ITALIC', 'Times-BoldItalic'),
    ('SYMBOL', 'Symbol'),
    ('ZAPF', 'ZapfDingbats'),
]


def wrap(text, indent, width=104):
    """把长字符串按行宽折成多行 ArkTS 字符串拼接，保证源码可读。"""
    words = text.split(' ')
    lines = []
    cur = ''
    for w in words:
        if cur and len(cur) + 1 + len(w) > width:
            lines.append(cur)
            cur = w
        else:
            cur = (cur + ' ' + w) if cur else w
    if cur:
        lines.append(cur)
    body = []
    for i, line in enumerate(lines):
        if i + 1 < len(lines):
            body.append(f"{indent}'{line} ' +")
        else:
            body.append(f"{indent}'{line}'")
    return '\n'.join(body)


def encoding_string(enc_name):
    table = _fontdata.encodings[enc_name]
    names = []
    for code in range(256):
        name = table[code] if code < len(table) else None
        names.append(name if name else '-')
    return ' '.join(names)


def width_string(font_name):
    widths = _fontdata.widthsByFontGlyph[font_name]
    parts = []
    for name in sorted(widths.keys()):
        parts.append(f'{name} {int(widths[name])}')
    return ' '.join(parts)


def unicode_string():
    used = set()
    for _, enc in ENCODINGS:
        table = _fontdata.encodings[enc]
        for name in table:
            if name:
                used.add(name)
    for _, font in WIDTH_FONTS:
        used.update(_fontdata.widthsByFontGlyph[font].keys())
    parts = []
    for name in sorted(used):
        uv = AGL2UV.get(name)
        if uv is None:
            continue
        parts.append(f'{name} {uv}')
    return ' '.join(parts)


def main():
    out = []
    out.append('/**')
    out.append(' * PDF 标准 14 字体的度量与编码表（本文件由 tools/gen/gen_pdf_metrics.py 生成，请勿手改）。')
    out.append(' *')
    out.append(' * 数据来源：')
    out.append(' *  - 字宽：Adobe AFM 官方度量（经 reportlab 内置的 widthsByFontGlyph 导出）；')
    out.append(' *  - 编码表：PDF 32000-1 附录 D 的 Standard / WinAnsi / MacRoman / Symbol / ZapfDingbats；')
    out.append(' *  - 字形名 → Unicode：Adobe Glyph List。')
    out.append(' *')
    out.append(' * 为了让源码体积可控，表都存成空格分隔的字符串，首次使用时才解析成 Map（见 PdfStdFonts）。')
    out.append(' * 编码表里的 `-` 表示该码位未定义。')
    out.append(' */')
    out.append('')
    out.append('export class PdfStdData {')
    for key, enc in ENCODINGS:
        out.append(f'  /** {enc}：码位 0~255 对应的字形名 */')
        out.append(f'  static readonly ENC_{key}: string =')
        out.append(wrap(encoding_string(enc), '    ') + ';')
        out.append('')
    out.append('  /** 字形名 → Unicode 码点（Adobe Glyph List 中本项目用得到的部分） */')
    out.append('  static readonly GLYPH_UNICODE: string =')
    out.append(wrap(unicode_string(), '    ') + ';')
    out.append('')
    for key, font in WIDTH_FONTS:
        out.append(f'  /** {font} 的字形宽度（单位 1/1000 em） */')
        out.append(f'  static readonly W_{key}: string =')
        out.append(wrap(width_string(font), '    ') + ';')
        out.append('')
    out.append('  /** Courier 系列是等宽字体，所有字形宽度都是 600 */')
    out.append('  static readonly COURIER_WIDTH: number = 600;')
    out.append('}')
    out.append('')
    text = '\n'.join(out)
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(text)
    print(f'written {OUT}: {len(text)} bytes')


if __name__ == '__main__':
    main()

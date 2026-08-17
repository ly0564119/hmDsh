/**
 * PDF 流过滤器解码。
 *
 * 支持：FlateDecode（复用 Inflate，自动跳过 zlib 头）、LZWDecode、
 * ASCII85Decode、ASCIIHexDecode、RunLengthDecode，以及 Flate/LZW 后置的
 * 预测器（Predictor 2 = TIFF 差分，10~15 = PNG 各种滤波）。
 *
 * 图像专用的 DCTDecode（JPEG）/ JPXDecode / CCITTFaxDecode / JBIG2Decode
 * 不在这里解码：前者交给系统图片解码器，后两者暂不支持，
 * 由调用方按 imageFilter() 的返回值决定怎么处理。
 */

import { Inflate } from '../common/Inflate';

/** 图像类过滤器名称，遇到它们要保留原始字节交给专门的解码器 */
export class PdfImageFilter {
  static readonly NONE: string = '';
  static readonly DCT: string = 'DCTDecode';
  static readonly JPX: string = 'JPXDecode';
  static readonly CCITT: string = 'CCITTFaxDecode';
  static readonly JBIG2: string = 'JBIG2Decode';

  /** 是否是「不在本模块解码」的图像过滤器 */
  static isImageFilter(name: string): boolean {
    return name === PdfImageFilter.DCT || name === PdfImageFilter.JPX ||
      name === PdfImageFilter.CCITT || name === PdfImageFilter.JBIG2;
  }
}

/** 预测器参数（Flate/LZW 的 DecodeParms） */
export class PdfPredictorParams {
  /** 1 = 无预测器，2 = TIFF 差分，>=10 = PNG 滤波 */
  predictor: number = 1;
  colors: number = 1;
  bitsPerComponent: number = 8;
  columns: number = 1;
  /** LZW 专用：早期切换编码宽度，默认 1 */
  earlyChange: number = 1;
}

export class PdfFilters {
  /**
   * FlateDecode：PDF 里的 Flate 流一般带 zlib 头（0x78 0x9C 等），
   * 但也有生成器直接给裸 DEFLATE，甚至前面多了空白字节，这里都要兼容。
   */
  static flate(data: Uint8Array): Uint8Array {
    let start = 0;
    // 跳过流开头可能残留的空白
    while (start < data.length && (data[start] === 0x0a || data[start] === 0x0d ||
      data[start] === 0x20 || data[start] === 0x09)) {
      start++;
    }
    if (start >= data.length) {
      return new Uint8Array(0);
    }
    const cmf = data[start];
    const flg = start + 1 < data.length ? data[start + 1] : 0;
    // zlib 头：低 4 位是压缩方法（8 = deflate），且 (CMF*256+FLG) 能被 31 整除
    const zlibHeader = (cmf & 0x0f) === 8 && ((cmf << 8) + flg) % 31 === 0;
    if (zlibHeader) {
      try {
        return Inflate.inflateRaw(data, start + 2, data.length - start - 2, 0);
      } catch (e) {
        // 头看着像 zlib 但解不开，退回按裸流再试
      }
    }
    return Inflate.inflateRaw(data, start, data.length - start, 0);
  }

  /**
   * LZWDecode（PDF 32000-1 7.4.4）：变长 LZW，码长 9~12 位，
   * 256 = 清表，257 = 结束。earlyChange=1 时提前一个码切换宽度（默认值）。
   */
  static lzw(data: Uint8Array, earlyChange: number): Uint8Array {
    const out: number[] = [];
    // 字典：每个条目 = 前缀码 + 一个字节，用两个数组表示，避免频繁建数组对象
    const prefix = new Int32Array(4096);
    const suffix = new Uint8Array(4096);
    let next = 258;
    let codeBits = 9;
    let prev = -1;
    let bitBuf = 0;
    let bitCount = 0;
    let pos = 0;
    const seq = new Uint8Array(4096);

    while (true) {
      while (bitCount < codeBits) {
        if (pos >= data.length) {
          return Uint8Array.from(out);
        }
        bitBuf = (bitBuf << 8) | data[pos];
        pos++;
        bitCount += 8;
      }
      const code = (bitBuf >>> (bitCount - codeBits)) & ((1 << codeBits) - 1);
      bitCount -= codeBits;
      if (code === 257) {
        break;
      }
      if (code === 256) {
        next = 258;
        codeBits = 9;
        prev = -1;
        continue;
      }
      // 展开当前码对应的字节串（字典是「前缀链」，要倒着展开）
      let seqLen = 0;
      let cur = code;
      if (cur >= next) {
        // 特殊情况 KwKwK：当前码还没进字典，用「前一串 + 前一串首字节」
        if (prev < 0) {
          break;
        }
        cur = prev;
        let c = cur;
        while (c >= 256) {
          seq[seqLen] = suffix[c];
          seqLen++;
          c = prefix[c];
        }
        seq[seqLen] = c;
        seqLen++;
        // 倒序写出 + 追加首字节
        for (let i = seqLen - 1; i >= 0; i--) {
          out.push(seq[i]);
        }
        out.push(seq[seqLen - 1]);
        if (next < 4096) {
          prefix[next] = prev;
          suffix[next] = seq[seqLen - 1];
          next++;
        }
      } else {
        let c = cur;
        while (c >= 256) {
          seq[seqLen] = suffix[c];
          seqLen++;
          c = prefix[c];
        }
        seq[seqLen] = c;
        seqLen++;
        for (let i = seqLen - 1; i >= 0; i--) {
          out.push(seq[i]);
        }
        if (prev >= 0 && next < 4096) {
          prefix[next] = prev;
          suffix[next] = seq[seqLen - 1];
          next++;
        }
      }
      prev = code;
      const limit = next + (earlyChange !== 0 ? 1 : 0);
      if (limit > 4095) {
        codeBits = 12;
      } else if (limit > 2047) {
        codeBits = 12;
      } else if (limit > 1023) {
        codeBits = 11;
      } else if (limit > 511) {
        codeBits = 10;
      } else {
        codeBits = 9;
      }
      if (codeBits > 12) {
        codeBits = 12;
      }
    }
    return Uint8Array.from(out);
  }

  /** ASCIIHexDecode：十六进制文本，`>` 结束 */
  static asciiHex(data: Uint8Array): Uint8Array {
    const out: number[] = [];
    let high = -1;
    for (let i = 0; i < data.length; i++) {
      const c = data[i];
      if (c === 0x3e) {
        break;
      }
      let v = -1;
      if (c >= 0x30 && c <= 0x39) {
        v = c - 0x30;
      } else if (c >= 0x41 && c <= 0x46) {
        v = c - 0x41 + 10;
      } else if (c >= 0x61 && c <= 0x66) {
        v = c - 0x61 + 10;
      } else {
        continue;
      }
      if (high < 0) {
        high = v;
      } else {
        out.push(high * 16 + v);
        high = -1;
      }
    }
    if (high >= 0) {
      out.push(high * 16);
    }
    return Uint8Array.from(out);
  }

  /** ASCII85Decode：5 个可打印字符编 4 字节，`z` 表示 4 个 0，`~>` 结束 */
  static ascii85(data: Uint8Array): Uint8Array {
    const out: number[] = [];
    const group = new Int32Array(5);
    let count = 0;
    let i = 0;
    // 可选的 `<~` 开头
    if (data.length >= 2 && data[0] === 0x3c && data[1] === 0x7e) {
      i = 2;
    }
    for (; i < data.length; i++) {
      const c = data[i];
      if (c === 0x7e) {
        break; // `~>`
      }
      if (c === 0x7a && count === 0) {
        out.push(0, 0, 0, 0);
        continue;
      }
      if (c < 0x21 || c > 0x75) {
        continue; // 空白与非法字符忽略
      }
      group[count] = c - 0x21;
      count++;
      if (count === 5) {
        let value = 0;
        for (let k = 0; k < 5; k++) {
          value = value * 85 + group[k];
        }
        out.push((value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff);
        count = 0;
      }
    }
    if (count > 0) {
      // 末尾不足 5 个字符：用 'u'(84) 补齐，输出 count-1 个字节
      let value = 0;
      for (let k = 0; k < 5; k++) {
        value = value * 85 + (k < count ? group[k] : 84);
      }
      const tail = [(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff];
      for (let k = 0; k < count - 1; k++) {
        out.push(tail[k]);
      }
    }
    return Uint8Array.from(out);
  }

  /** RunLengthDecode：0~127 表示后跟 n+1 个原始字节，129~255 表示下一个字节重复 257-n 次，128 结束 */
  static runLength(data: Uint8Array): Uint8Array {
    const out: number[] = [];
    let i = 0;
    while (i < data.length) {
      const n = data[i];
      i++;
      if (n === 128) {
        break;
      }
      if (n < 128) {
        const count = n + 1;
        for (let k = 0; k < count && i < data.length; k++) {
          out.push(data[i]);
          i++;
        }
      } else {
        if (i >= data.length) {
          break;
        }
        const b = data[i];
        i++;
        const count = 257 - n;
        for (let k = 0; k < count; k++) {
          out.push(b);
        }
      }
    }
    return Uint8Array.from(out);
  }

  /**
   * 预测器还原（Flate/LZW 之后）。
   *
   * PNG 滤波每行前面多一个滤波类型字节，还原时需要「上一行」的数据；
   * TIFF 差分（Predictor 2）只在行内做水平差分。
   */
  static applyPredictor(data: Uint8Array, params: PdfPredictorParams): Uint8Array {
    const predictor = params.predictor;
    if (predictor <= 1) {
      return data;
    }
    const colors = Math.max(1, params.colors);
    const bpc = Math.max(1, params.bitsPerComponent);
    const columns = Math.max(1, params.columns);
    const bpp = Math.max(1, Math.ceil(colors * bpc / 8)); // 每像素字节数（向上取整）
    const rowBytes = Math.ceil(colors * bpc * columns / 8);

    if (predictor === 2) {
      // TIFF 差分：只有 8 位分量的情况常见，其他位深按原样返回
      if (bpc !== 8) {
        return data;
      }
      const rows = Math.floor(data.length / rowBytes);
      for (let r = 0; r < rows; r++) {
        const base = r * rowBytes;
        for (let i = colors; i < rowBytes; i++) {
          data[base + i] = (data[base + i] + data[base + i - colors]) & 0xff;
        }
      }
      return data;
    }

    // PNG 系列滤波
    const rowCount = Math.floor(data.length / (rowBytes + 1));
    const out = new Uint8Array(rowCount * rowBytes);
    let prevRow = new Uint8Array(rowBytes);
    for (let r = 0; r < rowCount; r++) {
      const inBase = r * (rowBytes + 1);
      const filter = data[inBase];
      const outBase = r * rowBytes;
      for (let i = 0; i < rowBytes; i++) {
        const raw = data[inBase + 1 + i];
        const left = i >= bpp ? out[outBase + i - bpp] : 0;
        const up = prevRow[i];
        const upLeft = i >= bpp ? prevRow[i - bpp] : 0;
        let value = raw;
        if (filter === 1) {
          value = raw + left;
        } else if (filter === 2) {
          value = raw + up;
        } else if (filter === 3) {
          value = raw + ((left + up) >> 1);
        } else if (filter === 4) {
          // Paeth 预测
          const p = left + up - upLeft;
          const pa = Math.abs(p - left);
          const pb = Math.abs(p - up);
          const pc = Math.abs(p - upLeft);
          let pred = left;
          if (pb < pa && pb <= pc) {
            pred = up;
          } else if (pc < pa && pc < pb) {
            pred = upLeft;
          }
          value = raw + pred;
        }
        out[outBase + i] = value & 0xff;
      }
      prevRow = out.subarray(outBase, outBase + rowBytes);
    }
    return out;
  }
}

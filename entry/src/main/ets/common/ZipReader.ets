/**
 * 极简 ZIP 读取器，用于解出 .docx / .xlsx 内部的 XML（二者本质都是 ZIP 包）。
 * 只支持 STORE(0) 与 DEFLATE(8) 两种压缩方式。
 */

import { zlib } from '@kit.BasicServicesKit';

export class ZipEntry {
  name: string = '';
  method: number = 0;
  compressedSize: number = 0;
  uncompressedSize: number = 0;
  data: Uint8Array = new Uint8Array(0);
}

export class ZipReader {

  private static u16(b: Uint8Array, o: number): number {
    return b[o] | (b[o + 1] << 8);
  }

  private static u32(b: Uint8Array, o: number): number {
    return (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;
  }

  /** 在结尾 64KB 内定位 End of Central Directory */
  private static findEocd(b: Uint8Array): number {
    const min = Math.max(0, b.length - 65557);
    for (let i = b.length - 22; i >= min; i--) {
      if (b[i] === 0x50 && b[i + 1] === 0x4b && b[i + 2] === 0x05 && b[i + 3] === 0x06) {
        return i;
      }
    }
    return -1;
  }

  /** 按名称解出指定条目 */
  static extract(bytes: Uint8Array, wanted: string[]): ZipEntry[] {
    const result: ZipEntry[] = [];
    const eocd = ZipReader.findEocd(bytes);
    if (eocd < 0) {
      return result;
    }
    const count = ZipReader.u16(bytes, eocd + 10);
    let p = ZipReader.u32(bytes, eocd + 16); // central directory offset

    for (let n = 0; n < count; n++) {
      if (p + 46 > bytes.length) {
        break;
      }
      if (!(bytes[p] === 0x50 && bytes[p + 1] === 0x4b && bytes[p + 2] === 0x01 && bytes[p + 3] === 0x02)) {
        break;
      }
      const method = ZipReader.u16(bytes, p + 10);
      const compressedSize = ZipReader.u32(bytes, p + 20);
      const nameLen = ZipReader.u16(bytes, p + 28);
      const extraLen = ZipReader.u16(bytes, p + 30);
      const commentLen = ZipReader.u16(bytes, p + 32);
      const localOff = ZipReader.u32(bytes, p + 42);
      let name = '';
      for (let k = 0; k < nameLen; k++) {
        name += String.fromCharCode(bytes[p + 46 + k]);
      }

      // 是否需要该条目
      let need = false;
      for (let w = 0; w < wanted.length; w++) {
        if (name === wanted[w]) {
          need = true;
          break;
        }
      }

      if (need) {
        const entry = new ZipEntry();
        entry.name = name;
        entry.method = method;
        entry.compressedSize = compressedSize;
        // 本地头：+26 nameLen, +28 extraLen，数据从 +30+nameLen+extraLen 开始
        const lnLen = ZipReader.u16(bytes, localOff + 26);
        const leLen = ZipReader.u16(bytes, localOff + 28);
        const dataStart = localOff + 30 + lnLen + leLen;
        const dataEnd = dataStart + compressedSize;
        if (method === 0) {
          entry.data = bytes.subarray(dataStart, dataEnd);
        } else if (method === 8) {
          const src = bytes.subarray(dataStart, dataEnd);
          const inBuf = src.buffer.slice(src.byteOffset, src.byteOffset + src.byteLength);
          try {
            const out = zlib.decompressSync(inBuf, {
              format: zlib.CompressFormat.CompressFormatRAW_DEFLATE
            });
            entry.data = new Uint8Array(out);
          } catch (e) {
            entry.data = new Uint8Array(0);
          }
        }
        result.push(entry);
      }

      p = p + 46 + nameLen + extraLen + commentLen;
    }
    return result;
  }

  /** 读取单个条目文本（UTF-8） */
  static extractText(bytes: Uint8Array, name: string): string {
    const entries = ZipReader.extract(bytes, [name]);
    if (entries.length === 0 || entries[0].data.length === 0) {
      return '';
    }
    return ZipReader.decodeUtf8(entries[0].data);
  }

  /** 把 UTF-8 字节解码成字符串 */
  static decodeUtf8(data: Uint8Array): string {
    let out = '';
    let i = 0;
    while (i < data.length) {
      const b0 = data[i];
      if (b0 < 0x80) {
        out += String.fromCharCode(b0);
        i += 1;
      } else if (b0 < 0xe0) {
        out += String.fromCharCode(((b0 & 0x1f) << 6) | (data[i + 1] & 0x3f));
        i += 2;
      } else {
        out += String.fromCharCode(((b0 & 0x0f) << 12) | ((data[i + 1] & 0x3f) << 6) | (data[i + 2] & 0x3f));
        i += 3;
      }
    }
    return out;
  }
}

/**
 * UTF-8 解码（字节 → 字符串）。
 *
 * 自己实现而不用 util.TextDecoder，是为了让 ZIP/XML 解析这一层不依赖系统 API，
 * 既能在真机跑，也能被单元测试直接调用；同时顺手处理掉 Office XML 常见的 BOM。
 */

export class Utf8 {
  /** 攒够这么多字符就并入结果串，减少长字符串反复拼接 */
  private static readonly CHUNK: number = 4096;

  /**
   * 解码 UTF-8 字节序列。非法字节按 U+FFFD 替换，不抛异常。
   * @param bytes 待解码字节
   */
  static decode(bytes: Uint8Array): string {
    let start = 0;
    // 跳过 UTF-8 BOM（EF BB BF）
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      start = 3;
    }

    let out = '';
    let chunk = '';
    let i = start;
    const n = bytes.length;

    while (i < n) {
      const b0 = bytes[i];
      let cp = 0xfffd;
      if (b0 < 0x80) {
        cp = b0;
        i += 1;
      } else if (b0 >= 0xc2 && b0 <= 0xdf && i + 1 < n && Utf8.isCont(bytes[i + 1])) {
        cp = ((b0 & 0x1f) << 6) | (bytes[i + 1] & 0x3f);
        i += 2;
      } else if (b0 >= 0xe0 && b0 <= 0xef && i + 2 < n &&
        Utf8.isCont(bytes[i + 1]) && Utf8.isCont(bytes[i + 2])) {
        cp = ((b0 & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f);
        i += 3;
      } else if (b0 >= 0xf0 && b0 <= 0xf4 && i + 3 < n &&
        Utf8.isCont(bytes[i + 1]) && Utf8.isCont(bytes[i + 2]) && Utf8.isCont(bytes[i + 3])) {
        cp = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) |
          ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
        i += 4;
      } else {
        i += 1;
      }

      if (cp > 0xffff) {
        // 转成 UTF-16 代理对
        const v = cp - 0x10000;
        chunk += String.fromCharCode(0xd800 + (v >> 10));
        chunk += String.fromCharCode(0xdc00 + (v & 0x3ff));
      } else {
        chunk += String.fromCharCode(cp);
      }

      if (chunk.length >= Utf8.CHUNK) {
        out += chunk;
        chunk = '';
      }
    }

    if (chunk.length > 0) {
      out += chunk;
    }
    return out;
  }

  /** 是否是 UTF-8 续字节（10xxxxxx） */
  private static isCont(b: number): boolean {
    return (b & 0xc0) === 0x80;
  }
}

/**
 * PDF 颜色空间：把颜色分量转成打印用的 RGB。
 *
 * 支持 DeviceGray / DeviceRGB / DeviceCMYK / Indexed / ICCBased / CalRGB / CalGray /
 * Lab（近似）/ Separation / DeviceN / Pattern。
 *
 * 关于近似处理的说明（都写在这里，避免读代码时反复猜）：
 *  - Separation / DeviceN 的染色变换函数（tint transform）需要完整实现 PDF 函数对象
 *    （采样函数、指数函数、拼接函数、PostScript 计算器），对打印收益很小，
 *    这里按「墨量 t → 灰度 1-t」近似，专色黑、专色灰都能得到合理结果；
 *  - Pattern（渐变/平铺图案）不展开，按中性灰填充，避免整片纯黑或整片空白；
 *  - Lab 只用 L 分量近似成灰度，实际文档里 Lab 基本只出现在图片里。
 */

import { PdfDocument } from './PdfDocument';
import { PdfObj } from './PdfObject';

export class PdfColorSpace {
  static readonly GRAY: number = 0;
  static readonly RGB: number = 1;
  static readonly CMYK: number = 2;
  static readonly INDEXED: number = 3;
  static readonly SEPARATION: number = 4;
  static readonly PATTERN: number = 5;
  static readonly LAB: number = 6;

  /** 颜色空间种类 */
  readonly kind: number;
  /** 分量个数 */
  readonly components: number;
  /** Indexed：基础颜色空间 */
  base: PdfColorSpace | null = null;
  /** Indexed：调色板查找表（每项 base.components 个字节） */
  lookup: Uint8Array | null = null;
  /** Indexed：最大索引值 */
  hival: number = 0;

  constructor(kind: number, components: number) {
    this.kind = kind;
    this.components = components;
  }

  static deviceGray(): PdfColorSpace {
    return new PdfColorSpace(PdfColorSpace.GRAY, 1);
  }

  static deviceRgb(): PdfColorSpace {
    return new PdfColorSpace(PdfColorSpace.RGB, 3);
  }

  static deviceCmyk(): PdfColorSpace {
    return new PdfColorSpace(PdfColorSpace.CMYK, 4);
  }

  /**
   * 解析颜色空间对象。
   *
   * @param doc 文档
   * @param obj 颜色空间对象（名字或数组）
   * @param resources 当前资源字典，用于把 /CS0 这类名字在 /ColorSpace 里查出来
   */
  static parse(doc: PdfDocument, obj: PdfObj, resources: PdfObj): PdfColorSpace {
    return PdfColorSpace.parseDepth(doc, obj, resources, 0);
  }

  private static parseDepth(doc: PdfDocument, objIn: PdfObj, resources: PdfObj,
    depth: number): PdfColorSpace {
    if (depth > 8) {
      return PdfColorSpace.deviceGray();
    }
    const obj = doc.resolve(objIn);
    if (obj.isName()) {
      const name = obj.asName();
      const direct = PdfColorSpace.byName(name);
      if (direct !== null) {
        return direct;
      }
      // 资源字典里的命名颜色空间
      const dict = doc.dictGet(resources, 'ColorSpace');
      if (dict.isDict()) {
        const target = doc.dictGet(dict, name);
        if (!target.isNull()) {
          return PdfColorSpace.parseDepth(doc, target, resources, depth + 1);
        }
      }
      return PdfColorSpace.deviceGray();
    }
    if (!obj.isArray()) {
      return PdfColorSpace.deviceGray();
    }
    const arr = obj.asArray();
    if (arr.length === 0) {
      return PdfColorSpace.deviceGray();
    }
    const family = doc.resolve(arr[0]).asName();
    if (family === 'ICCBased') {
      const stream = arr.length > 1 ? doc.resolve(arr[1]) : PdfObj.NULL_OBJ;
      const n = Math.trunc(doc.numberOf(stream, 'N', 3));
      if (n === 1) {
        return PdfColorSpace.deviceGray();
      }
      if (n === 4) {
        return PdfColorSpace.deviceCmyk();
      }
      return PdfColorSpace.deviceRgb();
    }
    if (family === 'Indexed' || family === 'I') {
      const cs = new PdfColorSpace(PdfColorSpace.INDEXED, 1);
      cs.base = arr.length > 1
        ? PdfColorSpace.parseDepth(doc, arr[1], resources, depth + 1)
        : PdfColorSpace.deviceRgb();
      cs.hival = arr.length > 2 ? Math.trunc(doc.resolve(arr[2]).asNumber(0)) : 0;
      if (arr.length > 3) {
        const lookupObj = doc.resolve(arr[3]);
        if (lookupObj.isStream()) {
          cs.lookup = doc.getStreamData(lookupObj);
        } else if (lookupObj.isString()) {
          cs.lookup = lookupObj.asBytes();
        }
      }
      return cs;
    }
    if (family === 'Separation') {
      return new PdfColorSpace(PdfColorSpace.SEPARATION, 1);
    }
    if (family === 'DeviceN') {
      const names = arr.length > 1 ? doc.resolve(arr[1]).asArray() : [];
      return new PdfColorSpace(PdfColorSpace.SEPARATION, Math.max(1, names.length));
    }
    if (family === 'Pattern') {
      return new PdfColorSpace(PdfColorSpace.PATTERN, 1);
    }
    if (family === 'Lab') {
      return new PdfColorSpace(PdfColorSpace.LAB, 3);
    }
    if (family === 'CalRGB') {
      return PdfColorSpace.deviceRgb();
    }
    if (family === 'CalGray') {
      return PdfColorSpace.deviceGray();
    }
    const direct = PdfColorSpace.byName(family);
    if (direct !== null) {
      return direct;
    }
    return PdfColorSpace.deviceGray();
  }

  /** 设备颜色空间名 → 对象 */
  private static byName(name: string): PdfColorSpace | null {
    if (name === 'DeviceGray' || name === 'G' || name === 'CalGray') {
      return PdfColorSpace.deviceGray();
    }
    if (name === 'DeviceRGB' || name === 'RGB' || name === 'CalRGB') {
      return PdfColorSpace.deviceRgb();
    }
    if (name === 'DeviceCMYK' || name === 'CMYK') {
      return PdfColorSpace.deviceCmyk();
    }
    if (name === 'Pattern') {
      return new PdfColorSpace(PdfColorSpace.PATTERN, 1);
    }
    return null;
  }

  /** 0~255 夹取 */
  private static clamp255(v: number): number {
    if (v < 0) {
      return 0;
    }
    if (v > 255) {
      return 255;
    }
    return Math.round(v);
  }

  /** 打包成 0xRRGGBB */
  static pack(r: number, g: number, b: number): number {
    return (PdfColorSpace.clamp255(r) << 16) | (PdfColorSpace.clamp255(g) << 8) |
      PdfColorSpace.clamp255(b);
  }

  /**
   * 分量值（大多是 0~1）转 RGB。
   * @param values 分量数组，长度不足时按 0 处理
   * @returns 0xRRGGBB
   */
  toRgb(values: number[]): number {
    if (this.kind === PdfColorSpace.RGB) {
      return PdfColorSpace.pack(PdfColorSpace.at(values, 0) * 255,
        PdfColorSpace.at(values, 1) * 255, PdfColorSpace.at(values, 2) * 255);
    }
    if (this.kind === PdfColorSpace.GRAY) {
      const g = PdfColorSpace.at(values, 0) * 255;
      return PdfColorSpace.pack(g, g, g);
    }
    if (this.kind === PdfColorSpace.CMYK) {
      const c = PdfColorSpace.at(values, 0);
      const m = PdfColorSpace.at(values, 1);
      const y = PdfColorSpace.at(values, 2);
      const k = PdfColorSpace.at(values, 3);
      // 与打印机内部一致的朴素转换：R = 255(1-C)(1-K)
      return PdfColorSpace.pack(255 * (1 - c) * (1 - k), 255 * (1 - m) * (1 - k),
        255 * (1 - y) * (1 - k));
    }
    if (this.kind === PdfColorSpace.INDEXED) {
      return this.indexedToRgb(Math.round(PdfColorSpace.at(values, 0)));
    }
    if (this.kind === PdfColorSpace.SEPARATION) {
      // 近似：取最大墨量当灰度
      let t = 0;
      for (let i = 0; i < values.length; i++) {
        if (values[i] > t) {
          t = values[i];
        }
      }
      const g = 255 * (1 - t);
      return PdfColorSpace.pack(g, g, g);
    }
    if (this.kind === PdfColorSpace.LAB) {
      const l = PdfColorSpace.at(values, 0);
      const g = 255 * (l / 100);
      return PdfColorSpace.pack(g, g, g);
    }
    // Pattern：按中性灰处理
    return PdfColorSpace.pack(128, 128, 128);
  }

  private static at(values: number[], i: number): number {
    return i < values.length ? values[i] : 0;
  }

  /** Indexed：索引 → RGB */
  indexedToRgb(index: number): number {
    const base = this.base === null ? PdfColorSpace.deviceRgb() : this.base;
    const lookup = this.lookup;
    if (lookup === null) {
      const g = 255 * (index / Math.max(1, this.hival));
      return PdfColorSpace.pack(g, g, g);
    }
    const n = base.components;
    let idx = index;
    if (idx < 0) {
      idx = 0;
    }
    const offset = idx * n;
    const values: number[] = [];
    for (let i = 0; i < n; i++) {
      const byte = offset + i < lookup.length ? lookup[offset + i] : 0;
      // Lab 之外的基础空间分量都是 0~1，查找表里是 0~255
      values.push(byte / 255);
    }
    if (base.kind === PdfColorSpace.LAB) {
      values[0] = values[0] * 100;
    }
    return base.toRgb(values);
  }

  /** 该颜色空间的默认初始颜色（PDF 规定为「全 0」，即黑） */
  initialColor(): number {
    if (this.kind === PdfColorSpace.CMYK) {
      return PdfColorSpace.pack(0, 0, 0);
    }
    return PdfColorSpace.pack(0, 0, 0);
  }
}

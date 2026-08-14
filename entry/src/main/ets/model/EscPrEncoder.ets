/**
 * ESC/P-R（爱普生栅格协议）编码器，专为 L805 6 色照片打印机。
 *
 * 命令依据：Epson 官方开源驱动 epson-inkjet-printer-escpr
 * 的 lib/epson-escpage.c 与 lib/epson-escpage-color.c（ESC/P-R 颜色路径）。
 *
 * 关键点：
 *  - ESC/P-R 命令前缀是 GS（0x1D），不是 ESC（0x1B，那是老的 ESC/P2）。
 *  - 颜色栅格以 RGB888 直传（"2;102" 格式），L805 固件内部完成
 *    RGB→青/品/黄/黑/浅青/浅墨 的分色与抖动，主机无需分色。
 *  - 走 raw TCP 9100，先 EJL 握手再发 ESC/P-R 命令。
 */

import { ByteWriter } from '../common/ByteWriter';
import { RgbImage } from './RasterImage';

/** 打印分辨率（dpi） */
export class EscPrDpi {
  static readonly LOW: number = 300;
  static readonly HIGH: number = 600;
}

/** 纸张 */
export class EscPrPaper {
  static readonly A4: number = 0;
  static readonly LETTER: number = 1;
  static readonly POSTCARD: number = 2; // 4x6 近似（明信片）
}

export class PageDims {
  width: number = 0;
  height: number = 0;

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
  }
}

export class EscPrEncoder {
  /** 每带行数，与官方驱动压缩带一致 */
  static readonly BAND_ROWS: number = 64;

  private static psCode(paper: number): string {
    if (paper === EscPrPaper.LETTER) {
      return '30';
    }
    if (paper === EscPrPaper.POSTCARD) {
      return '38';
    }
    return '14'; // A4
  }

  private static ejlName(paper: number): string {
    if (paper === EscPrPaper.LETTER) {
      return 'LT';
    }
    if (paper === EscPrPaper.POSTCARD) {
      return 'PC';
    }
    return 'A4';
  }

  /** 可打印区（mm），由官方 300dpi 纸张表换算 */
  private static printableMm(paper: number): PageDims {
    if (paper === EscPrPaper.LETTER) {
      return new PageDims(209.97, 273.47);
    }
    if (paper === EscPrPaper.POSTCARD) {
      return new PageDims(94.06, 142.07);
    }
    return new PageDims(204.05, 291.07); // A4
  }

  /** 指定 dpi 下的可打印区像素尺寸（栅格宽高） */
  static printablePx(dpi: number, paper: number): PageDims {
    const mm = EscPrEncoder.printableMm(paper);
    return new PageDims(
      Math.round(mm.width / 25.4 * dpi),
      Math.round(mm.height / 25.4 * dpi)
    );
  }

  private static wStr(w: ByteWriter, s: string): void {
    for (let i = 0; i < s.length; i++) {
      w.writeByte(s.charCodeAt(i));
    }
  }

  private static wNum(w: ByteWriter, n: number): void {
    EscPrEncoder.wStr(w, n.toString());
  }

  /** EJL 作业开始（彩色） */
  private static writeEjlStart(w: ByteWriter, dpi: number, paper: number): void {
    const rs = dpi >= 600 ? 'FN' : 'QK';
    EscPrEncoder.wStr(w, '\x1b\x01@EJL \n');
    EscPrEncoder.wStr(w, '@EJL SE LA=ESC/PAGE\n');
    EscPrEncoder.wStr(w, '@EJL SET RS=' + rs +
      ' PS=' + EscPrEncoder.ejlName(paper) +
      ' PK=NM PU=AU OU=FD DX=OFF ZO=OFF EC=ON RI=ON SN=OFF CO=1 QT=1' +
      ' SZ=OFF GAMMAMODE=NORMAL SL=YES TO=0 LO=0 OR=PO \n');
    EscPrEncoder.wStr(w, '@EJL EN LA=ESC/PAGE-COLOR\n');
  }

  /** 页面逻辑原点/裁剪区（官方 ejlPageEsc） */
  private static writePageEsc(w: ByteWriter, width: number, height: number): void {
    EscPrEncoder.wStr(w, '\x1d0;0loE');                 // 逻辑原点 (0,0)
    EscPrEncoder.wStr(w, '\x1d0X');                     // 复位 X
    EscPrEncoder.wStr(w, '\x1d0Y');                     // 复位 Y
    EscPrEncoder.wStr(w, '\x1d0;0;' + width.toString() + ';' + height.toString() + 'caE'); // 裁剪区
  }

  /** 作业级页面初始化（官方 pageStartJob_C，彩色） */
  private static writeJobInit(w: ByteWriter, dpi: number, paper: number,
    width: number, height: number): void {
    EscPrEncoder.wStr(w, '\x1drhE');                    // 初始化打印机
    if (dpi >= 600) {
      EscPrEncoder.wStr(w, '\x1d0;.12muE');             // 单位 600dpi
      EscPrEncoder.wStr(w, '\x1d3;600;600drE');         // 点尺寸（颜色）
      EscPrEncoder.wStr(w, '\x1d2;600;600drE');         // 点尺寸（二值）
      EscPrEncoder.wStr(w, '\x1d1;600;600drE');         // 点尺寸（字体）
      EscPrEncoder.wStr(w, '\x1d0;600;600drE');         // 点尺寸（图像）
    } else {
      EscPrEncoder.wStr(w, '\x1d0;.24muE');             // 单位 300dpi
      EscPrEncoder.wStr(w, '\x1d3;300;300drE');
      EscPrEncoder.wStr(w, '\x1d2;300;300drE');
      EscPrEncoder.wStr(w, '\x1d1;300;300drE');
      EscPrEncoder.wStr(w, '\x1d0;300;300drE');
    }
    EscPrEncoder.wStr(w, '\x1d0mmE');                   // 页内存模式
    EscPrEncoder.wStr(w, '\x1d' + EscPrEncoder.psCode(paper) + 'psE'); // 纸张
    EscPrEncoder.writePageEsc(w, width, height);
    EscPrEncoder.wStr(w, '\x1d1cmE');                   // 裁剪模式
    EscPrEncoder.wStr(w, '\x1d0alfP');                  // 不自动回车换行
    EscPrEncoder.wStr(w, '\x1d0affP');                  // 不自动走纸
    EscPrEncoder.wStr(w, '\x1d1abP');                   // 位图绘制后复位位置
    EscPrEncoder.wStr(w, '\x0d');                       // CR
    EscPrEncoder.wStr(w, '\x1d2sarG');                  // 绝对图坐标模式
    EscPrEncoder.wStr(w, '\x1d0pmP');                   // 打印间距移动模式
    EscPrEncoder.wStr(w, '\x1d1ptE');                   // 纸张类型：普通纸
    EscPrEncoder.wStr(w, '\x1d0poE');                   // 纸张方向：正常
    EscPrEncoder.wStr(w, '\x1d0pddO');                  // 成像设备：CPGI
    EscPrEncoder.wStr(w, '\x1d2csE');                   // 色彩空间
    EscPrEncoder.wStr(w, '\x1d0cmmE');                  // 取消色彩管理
    EscPrEncoder.wStr(w, '\x1d0;2;4ccmE');              // 颜色收集
    EscPrEncoder.wStr(w, '\x1d7;0;2;3cam{E');           // 颜色条件
    EscPrEncoder.wStr(w, '\x1d1;1raE');                 // 加网 1
    EscPrEncoder.wStr(w, '\x1d2;1raE');                 // 加网 2
    EscPrEncoder.wStr(w, '\x1d3;2raE');                 // 加网 3
    EscPrEncoder.wStr(w, '\x1d1cmmE');                  // 启用色彩管理
    EscPrEncoder.wStr(w, '\x1d0;0;0clfP');              // 颜色查找
    EscPrEncoder.wStr(w, '\x1d5;204wfE');               // 逻辑运算
  }

  /** 发送一页 RGB888 颜色栅格（分带） */
  private static writeRgbPage(w: ByteWriter, rgb: Uint8Array, width: number, height: number): void {
    const rowBytes = width * 3;
    const stride = (rowBytes + 3) & ~3; // 每行 4 字节对齐
    let emitted = false;
    let y = 0;
    while (y < height) {
      const rows = Math.min(EscPrEncoder.BAND_ROWS, height - y);
      if (emitted) {
        EscPrEncoder.wStr(w, '\x1decrI');               // 结束上一段颜色图像
      } else {
        emitted = true;
      }
      EscPrEncoder.wStr(w, '\x1d0X');                   // 复位 X
      EscPrEncoder.wStr(w, '\x1d' + y.toString() + 'Y'); // 绝对 Y
      // 颜色图像头：2;102 = RGB888
      EscPrEncoder.wStr(w, '\x1d2;102;0;0;' +
        width.toString() + ';' + rows.toString() + ';' +
        width.toString() + ';' + rows.toString() + ';0scrI');
      // 未压缩数据头：cu{I
      EscPrEncoder.wStr(w, '\x1d' + (stride * rows).toString() + ';' +
        rows.toString() + 'cu{I');
      for (let r = 0; r < rows; r++) {
        const off = (y + r) * rowBytes;
        w.writeBytes(rgb.subarray(off, off + rowBytes));
        for (let pad = rowBytes; pad < stride; pad++) {
          w.writeByte(0);
        }
      }
      y += rows;
    }
  }

  /** EJL 作业结束 */
  private static writeEjlEnd(w: ByteWriter, pageCount: number): void {
    EscPrEncoder.wStr(w, '\x1decrI');                   // 结束颜色图像
    EscPrEncoder.wStr(w, '\x1b\x01@EJL JI PAGES="' + pageCount.toString() + '" \n@EJL \n');
  }

  /**
   * 构建完整打印任务。
   * @param pages 各页 RGB 位图（尺寸必须一致）
   * @param dpi 分辨率（300 / 600）
   * @param paper 纸张
   */
  static buildJob(pages: RgbImage[], dpi: number, paper: number): ArrayBuffer {
    const w = new ByteWriter(pages.length * pages[0].width * pages[0].height * 3 + 4096);
    EscPrEncoder.writeEjlStart(w, dpi, paper);
    EscPrEncoder.writeJobInit(w, dpi, paper, pages[0].width, pages[0].height);
    for (let i = 0; i < pages.length; i++) {
      if (i > 0) {
        w.writeByte(0x0c); // FF：换页
        EscPrEncoder.writePageEsc(w, pages[i].width, pages[i].height);
      }
      EscPrEncoder.writeRgbPage(w, pages[i].data, pages[i].width, pages[i].height);
    }
    EscPrEncoder.writeEjlEnd(w, pages.length);
    return w.toArrayBuffer();
  }
}

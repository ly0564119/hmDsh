/**
 * PDF → PageContent 的平台层：把显示列表里的图像流转成 PixelMap。
 *
 * 纯逻辑层已经把一页解释成 LaidPage（文字/路径的坐标都换算好了），
 * 这里只处理「必须用系统解码器」的 JPEG，以及「已经解成 RGBA」的位图。
 */

import { image } from '@kit.ImageKit';
import { Constants } from '../common/Constants';
import { PdfDocument } from '../pdf/PdfDocument';
import { PdfImageDecoder, PdfImageInfo } from '../pdf/PdfImage';
import { LaidImageRef, LaidItem, LaidKind, LaidPage } from '../pdf/PdfPageLayout';
import { DrawOp, ImageBox, PageContent, PathShape, StyledText } from './PageContent';

export class PdfPrint {
  /**
   * 把一页缩放结果物化成可绘制的 PageContent。
   * @param doc 用来读图像流 / SMask
   */
  static async materialize(doc: PdfDocument, laid: LaidPage): Promise<PageContent> {
    const page = new PageContent();
    for (let i = 0; i < laid.items.length; i++) {
      const item: LaidItem = laid.items[i];
      if (item.kind === LaidKind.TEXT && item.text !== null) {
        const t = item.text;
        const run = new StyledText();
        run.x = t.x;
        run.y = t.y;
        run.text = t.text;
        run.sizePx = t.sizePx;
        run.advances = t.advances;
        run.rotationDeg = t.rotationDeg;
        run.color = t.color;
        run.bold = t.bold;
        run.italic = t.italic;
        run.serif = t.serif;
        run.monospace = t.monospace;
        page.ops.push(DrawOp.ofText(run));
      } else if (item.kind === LaidKind.PATH && item.path !== null) {
        const p = item.path;
        const shape = new PathShape();
        shape.cmds = p.cmds;
        shape.hasFill = p.hasFill;
        shape.fillColor = p.fillColor;
        shape.evenOdd = p.evenOdd;
        shape.hasStroke = p.hasStroke;
        shape.strokeColor = p.strokeColor;
        shape.strokeWidth = p.strokeWidth;
        page.ops.push(DrawOp.ofPath(shape));
      } else if (item.kind === LaidKind.IMAGE && item.image !== null) {
        const box = await PdfPrint.decodeImage(doc, item.image);
        if (box !== null) {
          page.ops.push(DrawOp.ofImage(box));
        }
      }
    }
    return page;
  }

  /** 解码一张 PDF 图片并放到目标矩形上 */
  private static async decodeImage(doc: PdfDocument, ref: LaidImageRef): Promise<ImageBox | null> {
    if (ref.width < 0.5 || ref.height < 0.5) {
      return null;
    }
    const info: PdfImageInfo = PdfImageDecoder.describe(doc, ref.stream);
    const maxPixels = Math.min(Constants.MAX_PIXELS,
      Math.max(64, Math.ceil(ref.width) * Math.ceil(ref.height) * 4));
    let pixelMap: image.PixelMap | null = null;
    if (PdfImageDecoder.needsPlatformDecode(info)) {
      pixelMap = await PdfPrint.decodeWithImageKit(info.data, Math.ceil(ref.width), Math.ceil(ref.height));
    } else {
      const decoded = PdfImageDecoder.toRgba(doc, ref.stream, info, ref.maskColor, maxPixels);
      if (decoded !== null) {
        pixelMap = PdfPrint.rgbaToPixelMap(decoded.width, decoded.height, decoded.rgba);
      }
    }
    if (pixelMap === null) {
      return null;
    }
    return new ImageBox(pixelMap, ref.left, ref.top, ref.width, ref.height);
  }

  /** JPEG / JPEG2000：交给系统图片解码器 */
  private static async decodeWithImageKit(data: Uint8Array, destW: number,
    destH: number): Promise<image.PixelMap | null> {
    if (data.length < 8) {
      return null;
    }
    const copy = new ArrayBuffer(data.length);
    new Uint8Array(copy).set(data);
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(copy);
      const info = await source.getImageInfo();
      const srcW = info.size.width;
      const srcH = info.size.height;
      if (srcW <= 0 || srcH <= 0) {
        return null;
      }
      // 解码到「绘制所需」即可，再大浪费内存
      let dw = Math.max(1, Math.min(srcW, Math.ceil(Math.abs(destW))));
      let dh = Math.max(1, Math.min(srcH, Math.ceil(Math.abs(destH))));
      if (dw * dh > Constants.MAX_PIXELS) {
        const shrink = Math.sqrt(Constants.MAX_PIXELS / (dw * dh));
        dw = Math.max(1, Math.round(dw * shrink));
        dh = Math.max(1, Math.round(dh * shrink));
      }
      return await source.createPixelMap({
        desiredSize: { width: dw, height: dh },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    } catch (e) {
      return null;
    } finally {
      if (source !== null) {
        source.release();
      }
    }
  }

  /** RGBA 缓冲 → PixelMap */
  private static rgbaToPixelMap(width: number, height: number, rgba: Uint8Array): image.PixelMap {
    const buffer = new ArrayBuffer(width * height * 4);
    new Uint8Array(buffer).set(rgba.subarray(0, width * height * 4));
    return image.createPixelMapSync(buffer, {
      editable: false,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: width, height: height }
    });
  }
}

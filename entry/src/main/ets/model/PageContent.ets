/**
 * 页面内容模型：一页要画什么，用「与设备无关的页面像素坐标」描述。
 *
 * 排版（DocumentRasterizer）只产出这个模型，真正的像素绘制由 PageRenderer
 * 按渲染带（band）分块完成。这样整页栅格不必同时驻留内存——A4 720dpi
 * 整页 RGB 超过 100MB，手机上必须分带处理。
 */

import { image } from '@kit.ImageKit';

/** 一行文本 */
export class TextLine {
  /** 行首 x（页面坐标） */
  x: number = 0;
  /** 文字基线 y（页面坐标） */
  baselineY: number = 0;
  text: string = '';

  constructor(x: number, baselineY: number, text: string) {
    this.x = x;
    this.baselineY = baselineY;
    this.text = text;
  }
}

/** 一条直线（表格网格线） */
export class LineSeg {
  x0: number = 0;
  y0: number = 0;
  x1: number = 0;
  y1: number = 0;

  constructor(x0: number, y0: number, x1: number, y1: number) {
    this.x0 = x0;
    this.y0 = y0;
    this.x1 = x1;
    this.y1 = y1;
  }
}

/** 一张图片在页面上的摆放位置 */
export class ImageBox {
  pixelMap: image.PixelMap;
  left: number = 0;
  top: number = 0;
  width: number = 0;
  height: number = 0;

  constructor(pixelMap: image.PixelMap, left: number, top: number, width: number, height: number) {
    this.pixelMap = pixelMap;
    this.left = left;
    this.top = top;
    this.width = width;
    this.height = height;
  }
}

/** 一页的全部绘制内容 */
export class PageContent {
  /** 文本行 */
  texts: TextLine[] = [];
  /** 网格线 */
  strokes: LineSeg[] = [];
  /** 图片（照片打印时有值） */
  imageBox: ImageBox | null = null;

  /** 释放页面持有的原生资源（图片 PixelMap） */
  release(): void {
    if (this.imageBox !== null) {
      this.imageBox.pixelMap.release();
      this.imageBox = null;
    }
  }
}

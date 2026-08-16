import { promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { PrintJob, PrintRequest, PrintService, PrintSource } from '../model/PrintService';
import { PagePreview } from '../model/PageRenderer';
import {
  EscPrColorMode,
  EscPrDpi,
  EscPrJobOptions,
  EscPrMediaType,
  EscPrQuality
} from '../model/EscPrEncoder';
import { Constants, PaperSpec } from '../common/Constants';
import { PrinterDiscovery, DiscoveredPrinter } from '../model/PrinterDiscovery';

const TAG: string = 'L805Index';

@Entry
@Component
struct Index {
  @State ip: string = '';
  @State status: string = '就绪';
  @State busy: boolean = false;
  @State discovering: boolean = false;
  @State foundList: DiscoveredPrinter[] = [];
  @State paperIndex: number = 0;
  @State qualityIndex: number = 0;
  @State mediaIndex: number = 0;
  @State colorIndex: number = 0;
  /** 当前预览页的位图，undefined 表示还没有可预览的内容 */
  @State previewImage: image.PixelMap | undefined = undefined;
  /** 预览页序号（0 基） */
  @State previewPage: number = 0;
  /** 总页数 */
  @State pageCount: number = 0;
  /** 已选内容的名字 */
  @State sourceName: string = '';
  /** 正在解析/排版/渲染预览 */
  @State preparing: boolean = false;

  private service: PrintService = new PrintService();
  private discovery: PrinterDiscovery = new PrinterDiscovery();
  /** 已解析的内容来源（与打印设置无关） */
  private source: PrintSource | null = null;
  /** 按当前设置排好版的作业，预览与打印共用同一份 */
  private job: PrintJob | null = null;

  /** 纸张选项与规格一一对应 */
  private paperSpecs: PaperSpec[] = [
    Constants.PAPER_A4,
    Constants.PAPER_LETTER,
    Constants.PAPER_A5,
    Constants.PAPER_POSTCARD,
    Constants.PAPER_4X6,
    Constants.PAPER_5X7
  ];
  private paperOptions: SelectOption[] = [
    { value: 'A4' },
    { value: 'Letter' },
    { value: 'A5' },
    { value: '明信片 100×148' },
    { value: '4×6 照片' },
    { value: '5×7 照片' }
  ];
  private qualityOptions: SelectOption[] = [
    { value: '标准（360dpi）' },
    { value: '高质量（720dpi）' }
  ];
  /** 介质选项与 ESC/P-R 的 MTID 一一对应 */
  private mediaTypes: number[] = [
    EscPrMediaType.PLAIN,
    EscPrMediaType.PHOTO,
    EscPrMediaType.PREMIUM_GLOSSY,
    EscPrMediaType.MATTE
  ];
  private mediaOptions: SelectOption[] = [
    { value: '普通纸' },
    { value: '照片纸（光面）' },
    { value: '高级光面照片纸' },
    { value: '亚光纸' }
  ];
  private colorOptions: SelectOption[] = [
    { value: '彩色' },
    { value: '黑白' }
  ];

  aboutToAppear(): void {
    PersistentStorage.persistProp('printer_ip', '');
    const saved = AppStorage.get<string>('printer_ip');
    if (saved !== undefined && saved.length > 0) {
      this.ip = saved;
    }
  }

  aboutToDisappear(): void {
    // 正在打印时不能释放作业持有的位图，否则渲染中的页面会崩；交给 GC 回收
    if (!this.busy) {
      this.discardPreview();
    }
  }

  /** 按界面选择组装 ESC/P-R 作业参数 */
  private buildOptions(): EscPrJobOptions {
    const options = new EscPrJobOptions();
    options.dpi = this.qualityIndex === 1 ? EscPrDpi.HIGH : EscPrDpi.STANDARD;
    options.paper = this.paperSpecs[this.paperIndex];
    options.mediaType = this.mediaTypes[this.mediaIndex];
    options.quality = this.qualityIndex === 1 ? EscPrQuality.HIGH : EscPrQuality.NORMAL;
    options.colorMode = this.colorIndex === 1 ? EscPrColorMode.MONOCHROME : EscPrColorMode.COLOR;
    return options;
  }

  private buildRequest(): PrintRequest {
    const req = new PrintRequest(this.ip, this.buildOptions());
    req.progress = (message: string) => {
      this.status = message;
    };
    return req;
  }

  private errorText(e: object): string {
    const err = e as BusinessError;
    return (err.message !== undefined && err.message.length > 0) ? err.message : '未知错误';
  }

  private validateIp(): boolean {
    const t = this.ip.trim();
    if (t.length === 0) {
      this.status = '请先输入打印机 IP 地址';
      promptAction.showToast({ message: '请先输入打印机 IP 地址' });
      return false;
    }
    this.ip = t;
    AppStorage.setOrCreate('printer_ip', t);
    return true;
  }

  /** 从 URI 取末尾的文件名用于显示 */
  private fileNameOf(uri: string): string {
    const slash = uri.lastIndexOf('/');
    const name = slash >= 0 ? uri.substring(slash + 1) : uri;
    return name.length > 0 ? name : '未命名';
  }

  /** 丢弃当前预览与已解析内容，释放位图资源 */
  private discardPreview(): void {
    if (this.job !== null) {
      this.job.release();
      this.job = null;
    }
    this.source = null;
    this.previewImage = undefined;
    this.previewPage = 0;
    this.pageCount = 0;
    this.sourceName = '';
  }

  /**
   * 按当前打印设置重新排版并刷新预览。
   * 纸张/质量等一变就要重排，否则预览和实际打印会不一致。
   */
  private async refreshPreview(): Promise<void> {
    const source = this.source;
    if (source === null) {
      return;
    }
    this.preparing = true;
    try {
      const job = await this.service.prepare(this.buildRequest(), source);
      if (this.job !== null) {
        this.job.release();
      }
      this.job = job;
      this.pageCount = job.pageCount;
      if (this.previewPage >= job.pageCount) {
        this.previewPage = 0;
      }
      this.renderPreviewPage();
      this.status = '预览就绪，共 ' + job.pageCount + ' 页；确认无误后点「开始打印」';
    } catch (e) {
      const detail = this.errorText(e);
      hilog.error(0x0000, TAG, 'prepare preview failed: %{public}s', detail);
      this.discardPreview();
      this.status = '生成预览失败：' + detail;
      promptAction.showToast({ message: '生成预览失败：' + detail });
    } finally {
      this.preparing = false;
    }
  }

  /** 渲染当前页的预览图 */
  private renderPreviewPage(): void {
    const job = this.job;
    if (job === null) {
      return;
    }
    try {
      this.previewImage = PrintService.renderPreview(job, this.previewPage, PagePreview.TARGET_WIDTH);
    } catch (e) {
      const detail = this.errorText(e);
      hilog.error(0x0000, TAG, 'render preview failed: %{public}s', detail);
      this.status = '渲染预览失败：' + detail;
    }
  }

  /** 翻页 */
  private turnPage(delta: number): void {
    const target = this.previewPage + delta;
    if (this.job === null || target < 0 || target >= this.job.pageCount) {
      return;
    }
    this.previewPage = target;
    this.renderPreviewPage();
  }

  /** 打印设置变化后重排预览 */
  private onSettingsChanged(): void {
    if (this.source !== null) {
      this.refreshPreview();
    }
  }

  /** 解析选中的内容并生成预览（不连打印机、不打印） */
  private async loadAndPreview(loader: () => PrintSource): Promise<void> {
    this.busy = true;
    this.status = '正在解析文件…';
    try {
      this.discardPreview();
      const source = loader();
      this.source = source;
      this.sourceName = source.displayName;
      await this.refreshPreview();
    } catch (e) {
      const detail = this.errorText(e);
      hilog.error(0x0000, TAG, 'load source failed: %{public}s', detail);
      this.discardPreview();
      this.status = '打开失败：' + detail;
      promptAction.showToast({ message: '打开失败：' + detail });
    } finally {
      this.busy = false;
    }
  }

  /** 选文件：返回选中的 URI，取消或失败返回空串 */
  private async pickDocument(suffix: string): Promise<string> {
    const docPicker = new picker.DocumentViewPicker();
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    opts.fileSuffixFilters = [suffix];
    try {
      const uris = await docPicker.select(opts);
      if (uris.length === 0) {
        this.status = '未选择文件';
        return '';
      }
      return uris[0];
    } catch (e) {
      this.status = '已取消选择文件';
      return '';
    }
  }

  private async pickText(): Promise<void> {
    const uri = await this.pickDocument('.txt');
    if (uri.length === 0) {
      return;
    }
    await this.loadAndPreview(() => PrintService.loadText(uri, this.fileNameOf(uri)));
  }

  private async pickPhoto(): Promise<void> {
    const photoPicker = new photoAccessHelper.PhotoViewPicker();
    const opts = new photoAccessHelper.PhotoSelectOptions();
    opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    opts.maxSelectNumber = 1;
    let result: photoAccessHelper.PhotoSelectResult | null = null;
    try {
      result = await photoPicker.select(opts);
    } catch (e) {
      this.status = '已取消选择图片';
      return;
    }
    if (result === null || result.photoUris.length === 0) {
      this.status = '未选择图片';
      return;
    }
    const uri = result.photoUris[0];
    await this.loadAndPreview(() => PrintService.loadPhoto(uri, this.fileNameOf(uri)));
  }

  /** 选 Office 文件：kind ∈ {docx, xlsx} */
  private async pickOffice(kind: string): Promise<void> {
    const isWord = kind === 'docx';
    const uri = await this.pickDocument(isWord ? '.docx' : '.xlsx');
    if (uri.length === 0) {
      return;
    }
    if (isWord) {
      await this.loadAndPreview(() => PrintService.loadDocx(uri, this.fileNameOf(uri)));
    } else {
      await this.loadAndPreview(() => PrintService.loadXlsx(uri, this.fileNameOf(uri)));
    }
  }

  /** 确认预览后真正开始打印 */
  private async startPrint(): Promise<void> {
    const job = this.job;
    if (job === null) {
      promptAction.showToast({ message: '请先选择要打印的内容' });
      return;
    }
    if (!this.validateIp()) {
      return;
    }
    this.busy = true;
    this.status = '正在准备打印…';
    try {
      const pages = await this.service.printJob(this.buildRequest(), job);
      this.status = '打印完成，共 ' + pages + ' 页';
      promptAction.showToast({ message: '打印完成' });
    } catch (e) {
      const detail = this.errorText(e);
      hilog.error(0x0000, TAG, 'print failed: %{public}s', detail);
      this.status = '打印失败：' + detail;
      promptAction.showToast({ message: '打印失败：' + detail });
    } finally {
      this.busy = false;
    }
  }

  private async discover(): Promise<void> {
    this.discovering = true;
    this.foundList = [];
    this.status = '正在扫描局域网…';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const list = await this.discovery.scan(ctx, 4000);
      this.foundList = list;
      if (list.length === 0) {
        this.status = '未发现打印机，可手动输入 IP';
        promptAction.showToast({ message: '未发现打印机' });
      } else {
        this.status = '发现 ' + list.length + ' 台设备，点击填入 IP';
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'discovery failed: %{public}s', this.errorText(e));
      this.status = '扫描失败，请手动输入 IP';
    } finally {
      this.discovering = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text('爱普生 L805 打印')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 24 })

        Column({ space: 8 }) {
          Text('打印机 IP 地址')
            .fontSize(13)
            .foregroundColor('#666666')
            .width('100%')
          Row({ space: 8 }) {
            TextInput({ text: this.ip, placeholder: '例如 192.168.1.100' })
              .layoutWeight(1)
              .onChange((value: string) => {
                this.ip = value;
              })
            Button('发现')
              .enabled(!this.discovering && !this.busy)
              .onClick(() => {
                this.discover();
              })
          }
          .width('100%')

          if (this.foundList.length > 0) {
            ForEach(this.foundList, (item: DiscoveredPrinter) => {
              Button(item.name + '  (' + item.ip + ')')
                .width('100%')
                .fontSize(13)
                .onClick(() => {
                  this.ip = item.ip;
                  AppStorage.setOrCreate('printer_ip', item.ip);
                  this.status = '已选择 ' + item.ip;
                })
            }, (item: DiscoveredPrinter) => item.ip)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 8 }) {
          Text('纸张')
            .fontSize(13)
            .foregroundColor('#666666')
            .width('100%')
          Select(this.paperOptions)
            .selected(this.paperIndex)
            .value(this.paperOptions[this.paperIndex].value)
            .width('100%')
            .enabled(!this.busy && !this.preparing)
            .onSelect((index: number, value: string) => {
              this.paperIndex = index;
              this.onSettingsChanged();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 8 }) {
          Text('打印质量')
            .fontSize(13)
            .foregroundColor('#666666')
            .width('100%')
          Select(this.qualityOptions)
            .selected(this.qualityIndex)
            .value(this.qualityOptions[this.qualityIndex].value)
            .width('100%')
            .enabled(!this.busy && !this.preparing)
            .onSelect((index: number, value: string) => {
              this.qualityIndex = index;
              this.onSettingsChanged();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 8 }) {
          Text('纸张类型')
            .fontSize(13)
            .foregroundColor('#666666')
            .width('100%')
          Select(this.mediaOptions)
            .selected(this.mediaIndex)
            .value(this.mediaOptions[this.mediaIndex].value)
            .width('100%')
            .enabled(!this.busy && !this.preparing)
            .onSelect((index: number, value: string) => {
              this.mediaIndex = index;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 8 }) {
          Text('色彩')
            .fontSize(13)
            .foregroundColor('#666666')
            .width('100%')
          Select(this.colorOptions)
            .selected(this.colorIndex)
            .value(this.colorOptions[this.colorIndex].value)
            .width('100%')
            .enabled(!this.busy && !this.preparing)
            .onSelect((index: number, value: string) => {
              this.colorIndex = index;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Text('选择要打印的内容（选完先看预览，确认后再打印）')
          .fontSize(13)
          .foregroundColor('#666666')
          .width('100%')

        Row({ space: 10 }) {
          Button('文本 .txt')
            .layoutWeight(1)
            .fontSize(14)
            .enabled(!this.busy && !this.preparing)
            .onClick(() => {
              this.pickText();
            })
          Button('照片')
            .layoutWeight(1)
            .fontSize(14)
            .enabled(!this.busy && !this.preparing)
            .onClick(() => {
              this.pickPhoto();
            })
        }
        .width('100%')

        Row({ space: 10 }) {
          Button('Word .docx')
            .layoutWeight(1)
            .fontSize(14)
            .enabled(!this.busy && !this.preparing)
            .onClick(() => {
              this.pickOffice('docx');
            })
          Button('Excel .xlsx')
            .layoutWeight(1)
            .fontSize(14)
            .enabled(!this.busy && !this.preparing)
            .onClick(() => {
              this.pickOffice('xlsx');
            })
        }
        .width('100%')

        if (this.previewImage !== undefined) {
          Column({ space: 10 }) {
            Text('打印预览 · ' + this.sourceName)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            // 预览图画的是整张纸（含页边距留白），所以直接铺白底加个边框看纸张边界
            Image(this.previewImage as image.PixelMap)
              .width('100%')
              .constraintSize({ maxHeight: 460 })
              .objectFit(ImageFit.Contain)
              .backgroundColor('#ffffff')
              .border({ width: 1, color: '#d0d0d0' })

            Row({ space: 12 }) {
              Button('上一页')
                .layoutWeight(1)
                .fontSize(14)
                .enabled(this.previewPage > 0 && !this.busy && !this.preparing)
                .onClick(() => {
                  this.turnPage(-1);
                })
              Text(`${this.previewPage + 1} / ${this.pageCount}`)
                .fontSize(14)
                .foregroundColor('#333333')
              Button('下一页')
                .layoutWeight(1)
                .fontSize(14)
                .enabled(this.previewPage + 1 < this.pageCount && !this.busy && !this.preparing)
                .onClick(() => {
                  this.turnPage(1);
                })
            }
            .width('100%')

            Button(this.busy ? '打印中…' : '开始打印')
              .width('100%')
              .type(ButtonType.Capsule)
              .enabled(!this.busy && !this.preparing)
              .onClick(() => {
                this.startPrint();
              })

            Button('重新选择')
              .width('100%')
              .fontSize(14)
              .backgroundColor('#eeeeee')
              .fontColor('#333333')
              .enabled(!this.busy && !this.preparing)
              .onClick(() => {
                this.discardPreview();
                this.status = '已清空预览';
              })
          }
          .width('100%')
          .padding({ top: 6 })
          .alignItems(HorizontalAlign.Center)
        }

        if (this.preparing) {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(20)
              .height(20)
            Text('正在生成预览…')
              .fontSize(13)
              .foregroundColor('#666666')
          }
        }

        Text(this.status)
          .fontSize(14)
          .foregroundColor('#333333')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }
      .width('100%')
      .padding({ left: 24, right: 24, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
  }
}

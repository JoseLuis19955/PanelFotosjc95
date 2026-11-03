// Panel Fotos - app nativa para Dopamine (rootless), iOS 15+
// Panel de fotos manipulable + panel de controles (zoom/pan, color de fondo,
// camara en vivo frontal, luz de pantalla, chroma key, bloqueo y filtros).
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

static const CGFloat kWorld  = 20000.0;
static const CGFloat kWorldC = 10000.0;

#pragma mark - Utilidades de color

static NSString *HexFromColor(UIColor *c) {
    CGFloat r=0,g=0,b=0,a=0; [c getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"%02lX%02lX%02lX", (long)(r*255), (long)(g*255), (long)(b*255)];
}
static UIColor *ColorFromHex(NSString *hex) {
    if (hex.length < 6) return nil;
    unsigned int v=0; NSScanner *sc = [NSScanner scannerWithString:hex]; [sc scanHexInt:&v];
    return [UIColor colorWithRed:((v>>16)&0xFF)/255.0 green:((v>>8)&0xFF)/255.0 blue:(v&0xFF)/255.0 alpha:1.0];
}

// Genera un filtro CIColorCube que vuelve transparente el color indicado (chroma key).
static CIFilter *ChromaKeyFilter(UIColor *key) {
    CGFloat h=0, s=0, br=0;
    [key getHue:&h saturation:&s brightness:&br alpha:NULL];
    const size_t size = 48;
    const size_t total = size*size*size*4;
    float *cube = (float *)malloc(total * sizeof(float));
    size_t offset = 0;
    for (size_t bz = 0; bz < size; bz++) {
        for (size_t gy = 0; gy < size; gy++) {
            for (size_t rx = 0; rx < size; rx++) {
                float rf = rx/(float)(size-1), gf = gy/(float)(size-1), bf = bz/(float)(size-1);
                CGFloat hue=0, sat=0;
                [[UIColor colorWithRed:rf green:gf blue:bf alpha:1] getHue:&hue saturation:&sat brightness:NULL alpha:NULL];
                CGFloat dh = fabs(hue - h); if (dh > 0.5) dh = 1.0 - dh;
                float alpha = (dh < 0.09 && sat > 0.25) ? 0.0f : 1.0f;
                cube[offset+0] = rf * alpha;
                cube[offset+1] = gf * alpha;
                cube[offset+2] = bf * alpha;
                cube[offset+3] = alpha;
                offset += 4;
            }
        }
    }
    NSData *data = [NSData dataWithBytesNoCopy:cube length:total*sizeof(float) freeWhenDone:YES];
    CIFilter *f = [CIFilter filterWithName:@"CIColorCube"];
    [f setValue:@(size) forKey:@"inputCubeDimension"];
    [f setValue:data forKey:@"inputCubeData"];
    return f;
}

#pragma mark - PhotoView

@interface PhotoView : UIImageView
@property (nonatomic, copy) NSString *fileName;
@end
@implementation PhotoView
@end

#pragma mark - BoardController

@interface BoardController : UIViewController <UIGestureRecognizerDelegate, PHPickerViewControllerDelegate,
    UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIColorPickerViewControllerDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) UIView *world;
@property (nonatomic, strong) UIToolbar *toolbar;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, weak) PhotoView *selected;
@property (nonatomic) CGFloat boardScale;
@property (nonatomic) BOOL loaded;
@property (nonatomic, copy) NSString *dir;

// panel de controles
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIButton *bgSwatch;
@property (nonatomic, strong) UIButton *liveBtn;
@property (nonatomic, strong) UISwitch *lightSwitch;
@property (nonatomic, strong) UISwitch *chromaSwitch;
@property (nonatomic, strong) UIButton *chromaGreenBtn, *chromaBlueBtn;
@property (nonatomic, strong) UISwitch *lockSwitch;

// camara en vivo
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) dispatch_queue_t camQueue;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) UIImageView *liveView;
@property (nonatomic, strong) UIView *lightOverlay;
@property (nonatomic) BOOL liveOn, chromaOn, lightOn, locked;
@property (nonatomic, strong) UIColor *chromaColor;
@property (nonatomic, strong) UIColor *bgColor;
@property (nonatomic) CGFloat savedBrightness;

@end

@implementation BoardController

#pragma mark Ciclo de vida

- (void)viewDidLoad {
    [super viewDidLoad];
    self.boardScale = 1;
    self.chromaColor = [UIColor colorWithRed:0.10 green:0.80 blue:0.30 alpha:1]; // verde por defecto
    self.bgColor = nil;
    self.camQueue = dispatch_queue_create("com.panelfotos.cam", DISPATCH_QUEUE_SERIAL);
    self.ciContext = [CIContext contextWithOptions:nil];

    self.view.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:0.09 alpha:1] : [UIColor colorWithWhite:0.95 alpha:1];
    }];
    self.view.multipleTouchEnabled = YES;

    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    self.dir = [base stringByAppendingPathComponent:@"PanelFotos"];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.dir withIntermediateDirectories:YES attributes:nil error:nil];

    // vista de camara en vivo (debajo o encima del lienzo segun chroma key)
    self.liveView = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.liveView.contentMode = UIViewContentModeScaleAspectFill;
    self.liveView.clipsToBounds = YES;
    self.liveView.hidden = YES;
    self.liveView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.liveView];

    self.lightOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
    self.lightOverlay.backgroundColor = [UIColor whiteColor];
    self.lightOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.lightOverlay.hidden = YES;
    self.lightOverlay.userInteractionEnabled = NO;
    [self.view addSubview:self.lightOverlay];

    self.world = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kWorld, kWorld)];
    self.world.multipleTouchEnabled = YES;
    [self.view addSubview:self.world];

    UIPanGestureRecognizer *bp = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(boardPan:)];
    bp.delegate = self; bp.maximumNumberOfTouches = 2;
    UIPinchGestureRecognizer *bz = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(boardPinch:)];
    bz.delegate = self;
    UITapGestureRecognizer *bt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(boardTap:)];
    bt.delegate = self;
    [self.view addGestureRecognizer:bp];
    [self.view addGestureRecognizer:bz];
    [self.view addGestureRecognizer:bt];

    [self buildBottomToolbar];
    [self buildControlsPanel];

    self.hint = [[UILabel alloc] init];
    self.hint.translatesAutoresizingMaskIntoConstraints = NO;
    self.hint.numberOfLines = 0;
    self.hint.textAlignment = NSTextAlignmentCenter;
    self.hint.textColor = [UIColor secondaryLabelColor];
    self.hint.font = [UIFont systemFontOfSize:15];
    self.hint.text = @"Usa el panel \u201cControles\u201d arriba, o toca Men\u00fa para a\u00f1adir fotos.\n\n1 dedo: mover \u00b7 2 dedos: zoom y girar una foto";
    self.hint.userInteractionEnabled = NO;
    [self.view insertSubview:self.hint belowSubview:self.toolbar];
    [NSLayoutConstraint activateConstraints:@[
        [self.hint.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.hint.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.hint.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-48]
    ]];
    [self updateUI];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.loaded) { self.loaded = YES; [self load]; }
}

#pragma mark Barra inferior (Menu / Filtros)

- (void)buildBottomToolbar {
    self.toolbar = [[UIToolbar alloc] init];
    self.toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.toolbar];
    [NSLayoutConstraint activateConstraints:@[
        [self.toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.toolbar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *menu = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal"] style:UIBarButtonItemStylePlain target:self action:@selector(menuTapped)];
    menu.title = @"Men\u00fa";
    UIBarButtonItem *filt = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"slider.horizontal.3"] style:UIBarButtonItemStylePlain target:self action:@selector(filtersTapped)];
    filt.title = @"Filtros";
    self.toolbar.items = @[menu, flex, filt];
}

#pragma mark Panel de controles (como en la captura)

- (UIButton *)iconButton:(NSString *)sysName action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:sysName] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithRed:0.16 green:0.24 blue:0.45 alpha:1];
    b.tintColor = [UIColor whiteColor];
    b.layer.cornerRadius = 10;
    [b.widthAnchor constraintEqualToConstant:44].active = YES;
    [b.heightAnchor constraintEqualToConstant:40].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UILabel *)rowLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text; l.textColor = [UIColor whiteColor]; l.font = [UIFont systemFontOfSize:15];
    return l;
}

- (void)buildControlsPanel {
    self.panel = [[UIView alloc] init];
    self.panel.translatesAutoresizingMaskIntoConstraints = NO;
    self.panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    self.panel.layer.cornerRadius = 16;
    [self.view addSubview:self.panel];
    [NSLayoutConstraint activateConstraints:@[
        [self.panel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10],
        [self.panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10]
    ]];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Controles"; title.textColor = [UIColor whiteColor]; title.font = [UIFont boldSystemFontOfSize:16];

    // fila de zoom / flechas / exportar
    UIButton *zoomOut = [self iconButton:@"minus.magnifyingglass" action:@selector(zoomOutTapped)];
    UIButton *zoomIn  = [self iconButton:@"plus.magnifyingglass" action:@selector(zoomInTapped)];
    UIButton *up    = [self iconButton:@"arrow.up" action:@selector(panUp)];
    UIButton *down  = [self iconButton:@"arrow.down" action:@selector(panDown)];
    UIButton *left  = [self iconButton:@"arrow.left" action:@selector(panLeft)];
    UIButton *right = [self iconButton:@"arrow.right" action:@selector(panRight)];
    UIButton *center = [self iconButton:@"arrow.counterclockwise" action:@selector(homeTapped)];
    UIButton *snap  = [self iconButton:@"square.and.arrow.down" action:@selector(exportSnapshot)];

    UIStackView *arrowsMid = [[UIStackView alloc] initWithArrangedSubviews:@[left, center, right]];
    arrowsMid.axis = UILayoutConstraintAxisHorizontal; arrowsMid.spacing = 8; arrowsMid.distribution = UIStackViewDistributionEqualSpacing;

    UIStackView *arrowsCol = [[UIStackView alloc] initWithArrangedSubviews:@[up, arrowsMid, down]];
    arrowsCol.axis = UILayoutConstraintAxisVertical; arrowsCol.spacing = 8; arrowsCol.alignment = UIStackViewAlignmentCenter;

    UIStackView *zoomCol = [[UIStackView alloc] initWithArrangedSubviews:@[zoomOut, zoomIn]];
    zoomCol.axis = UILayoutConstraintAxisVertical; zoomCol.spacing = 8;

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[zoomCol, arrowsCol, snap]];
    topRow.axis = UILayoutConstraintAxisHorizontal; topRow.spacing = 14; topRow.alignment = UIStackViewAlignmentCenter; topRow.distribution = UIStackViewDistributionEqualSpacing;

    // color de fondo
    self.bgSwatch = [UIButton buttonWithType:UIButtonTypeSystem];
    self.bgSwatch.backgroundColor = [UIColor whiteColor];
    self.bgSwatch.layer.cornerRadius = 14;
    self.bgSwatch.layer.borderWidth = 1; self.bgSwatch.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    [self.bgSwatch.widthAnchor constraintEqualToConstant:28].active = YES;
    [self.bgSwatch.heightAnchor constraintEqualToConstant:28].active = YES;
    [self.bgSwatch addTarget:self action:@selector(pickBgColor) forControlEvents:UIControlEventTouchUpInside];
    UIButton *pencil = [self iconButton:@"pencil" action:@selector(pickBgColor)];
    UIStackView *bgRow = [[UIStackView alloc] initWithArrangedSubviews:@[[self rowLabel:@"Color de Fondo"], [[UIView alloc] init], self.bgSwatch, pencil]];
    bgRow.axis = UILayoutConstraintAxisHorizontal; bgRow.spacing = 10; bgRow.alignment = UIStackViewAlignmentCenter;

    // movimiento en vivo
    self.liveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.liveBtn setTitle:@"Movimiento En Vivo" forState:UIControlStateNormal];
    [self.liveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.liveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.liveBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.45 blue:0.15 alpha:1];
    self.liveBtn.layer.cornerRadius = 10;
    [self.liveBtn.heightAnchor constraintEqualToConstant:40].active = YES;
    [self.liveBtn addTarget:self action:@selector(toggleLive) forControlEvents:UIControlEventTouchUpInside];

    // luz de pantalla
    self.lightSwitch = [[UISwitch alloc] init];
    [self.lightSwitch addTarget:self action:@selector(toggleLight) forControlEvents:UIControlEventValueChanged];
    UIStackView *lightRow = [[UIStackView alloc] initWithArrangedSubviews:@[[self rowLabel:@"Luz de Pantalla"], [[UIView alloc] init], self.lightSwitch]];
    lightRow.axis = UILayoutConstraintAxisHorizontal; lightRow.alignment = UIStackViewAlignmentCenter;

    // chroma key
    self.chromaSwitch = [[UISwitch alloc] init];
    [self.chromaSwitch addTarget:self action:@selector(toggleChroma) forControlEvents:UIControlEventValueChanged];
    self.chromaGreenBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.chromaGreenBtn.backgroundColor = [UIColor colorWithRed:0.10 green:0.80 blue:0.30 alpha:1];
    self.chromaGreenBtn.layer.cornerRadius = 12; self.chromaGreenBtn.layer.borderWidth = 2;
    [self.chromaGreenBtn.widthAnchor constraintEqualToConstant:24].active = YES;
    [self.chromaGreenBtn.heightAnchor constraintEqualToConstant:24].active = YES;
    [self.chromaGreenBtn addTarget:self action:@selector(pickChromaGreen) forControlEvents:UIControlEventTouchUpInside];
    self.chromaBlueBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.chromaBlueBtn.backgroundColor = [UIColor colorWithRed:0.10 green:0.30 blue:0.95 alpha:1];
    self.chromaBlueBtn.layer.cornerRadius = 12; self.chromaBlueBtn.layer.borderWidth = 2;
    self.chromaBlueBtn.layer.borderColor = [UIColor clearColor].CGColor;
    [self.chromaBlueBtn.widthAnchor constraintEqualToConstant:24].active = YES;
    [self.chromaBlueBtn.heightAnchor constraintEqualToConstant:24].active = YES;
    [self.chromaBlueBtn addTarget:self action:@selector(pickChromaBlue) forControlEvents:UIControlEventTouchUpInside];
    self.chromaGreenBtn.layer.borderColor = [UIColor whiteColor].CGColor;
    UIStackView *chromaRow = [[UIStackView alloc] initWithArrangedSubviews:@[[self rowLabel:@"Chroma Key"], [[UIView alloc] init], self.chromaSwitch, self.chromaGreenBtn, self.chromaBlueBtn]];
    chromaRow.axis = UILayoutConstraintAxisHorizontal; chromaRow.spacing = 10; chromaRow.alignment = UIStackViewAlignmentCenter;

    // guardar config / bloquear
    self.lockSwitch = [[UISwitch alloc] init];
    [self.lockSwitch addTarget:self action:@selector(toggleLock) forControlEvents:UIControlEventValueChanged];
    UIStackView *lockRow = [[UIStackView alloc] initWithArrangedSubviews:@[[self rowLabel:@"Bloquear Panel (Guardar Config)"], [[UIView alloc] init], self.lockSwitch]];
    lockRow.axis = UILayoutConstraintAxisHorizontal; lockRow.alignment = UIStackViewAlignmentCenter;

    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:@[title, topRow, bgRow, self.liveBtn, lightRow, chromaRow, lockRow]];
    v.axis = UILayoutConstraintAxisVertical; v.spacing = 12;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.panel addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:self.panel.topAnchor constant:12],
        [v.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor constant:14],
        [v.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor constant:-14],
        [v.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor constant:-14]
    ]];
}

#pragma mark Tablero (pan/zoom con el panel)

- (void)zoomStep:(CGFloat)factor {
    CGPoint center = CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2);
    CGPoint L = [self.world convertPoint:center fromView:self.view];
    CGFloat s = MAX(0.1, MIN(6.0, self.boardScale * factor));
    [UIView animateWithDuration:0.2 animations:^{
        self.world.transform = CGAffineTransformMakeScale(s, s);
        self.world.center = CGPointMake(center.x - s*(L.x-kWorldC), center.y - s*(L.y-kWorldC));
    } completion:^(BOOL f){ [self save]; }];
    self.boardScale = s;
}
- (void)zoomInTapped { [self zoomStep:1.25]; }
- (void)zoomOutTapped { [self zoomStep:0.8]; }
- (void)panBy:(CGPoint)d {
    [UIView animateWithDuration:0.15 animations:^{
        self.world.center = CGPointMake(self.world.center.x + d.x, self.world.center.y + d.y);
    } completion:^(BOOL f){ [self save]; }];
}
- (void)panUp    { [self panBy:CGPointMake(0, 70)]; }
- (void)panDown  { [self panBy:CGPointMake(0, -70)]; }
- (void)panLeft  { [self panBy:CGPointMake(70, 0)]; }
- (void)panRight { [self panBy:CGPointMake(-70, 0)]; }

- (void)boardPan:(UIPanGestureRecognizer *)g {
    if (self.locked) return;
    CGPoint t = [g translationInView:self.view];
    self.world.center = CGPointMake(self.world.center.x + t.x, self.world.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.view];
    if (g.state == UIGestureRecognizerStateEnded) [self save];
}
- (void)boardPinch:(UIPinchGestureRecognizer *)g {
    if (self.locked) return;
    CGPoint F = [g locationInView:self.view];
    CGPoint L = [self.world convertPoint:F fromView:self.view];
    CGFloat s = MAX(0.1, MIN(6.0, self.boardScale * g.scale));
    g.scale = 1;
    self.world.transform = CGAffineTransformMakeScale(s, s);
    self.world.center = CGPointMake(F.x - s*(L.x-kWorldC), F.y - s*(L.y-kWorldC));
    self.boardScale = s;
    if (g.state == UIGestureRecognizerStateEnded) [self save];
}
- (void)boardTap:(UITapGestureRecognizer *)g { [self select:nil]; }

#pragma mark Fotos (igual que antes: mover/zoom/girar con los dedos)

- (PhotoView *)makePhoto:(UIImage *)img file:(NSString *)file {
    CGFloat w = 240, h = w * img.size.height / MAX(1, img.size.width);
    PhotoView *p = [[PhotoView alloc] initWithImage:img];
    p.frame = CGRectMake(0, 0, w, h);
    p.fileName = file;
    p.userInteractionEnabled = YES;
    p.multipleTouchEnabled = YES;
    p.layer.borderWidth = 6;
    p.layer.borderColor = [UIColor whiteColor].CGColor;
    p.layer.shadowColor = [UIColor blackColor].CGColor;
    p.layer.shadowOpacity = 0.35;
    p.layer.shadowRadius = 8;
    p.layer.shadowOffset = CGSizeMake(0, 4);
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(photoPan:)];
    UIPinchGestureRecognizer *pin = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(photoPinch:)];
    UIRotationGestureRecognizer *rot = [[UIRotationGestureRecognizer alloc] initWithTarget:self action:@selector(photoRotate:)];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(photoTap:)];
    for (UIGestureRecognizer *r in @[pan, pin, rot, tap]) { r.delegate = self; [p addGestureRecognizer:r]; }
    pan.maximumNumberOfTouches = 2;
    return p;
}

- (void)addImage:(UIImage *)img file:(NSString *)file index:(int)idx {
    PhotoView *p = [self makePhoto:img file:file];
    CGPoint c = [self.world convertPoint:CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2) fromView:self.view];
    p.center = CGPointMake(c.x + idx*26, c.y + idx*26);
    p.transform = CGAffineTransformMakeRotation(((idx % 5) - 2) * 0.04);
    [self.world addSubview:p];
    [self select:p];
    [self save];
}

- (void)photoPan:(UIPanGestureRecognizer *)g {
    if (self.locked) return;
    PhotoView *p = (PhotoView *)g.view;
    if (g.state == UIGestureRecognizerStateBegan) [self select:p];
    CGPoint t = [g translationInView:self.world];
    p.center = CGPointMake(p.center.x + t.x, p.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.world];
    if (g.state == UIGestureRecognizerStateEnded) [self save];
}
- (void)photoPinch:(UIPinchGestureRecognizer *)g {
    if (self.locked) return;
    PhotoView *p = (PhotoView *)g.view;
    if (g.state == UIGestureRecognizerStateBegan) [self select:p];
    CGFloat cur = hypot(p.transform.a, p.transform.b);
    CGFloat n = MAX(0.1, MIN(10.0, cur * g.scale));
    CGFloat k = n / cur;
    p.transform = CGAffineTransformScale(p.transform, k, k);
    g.scale = 1;
    if (g.state == UIGestureRecognizerStateEnded) [self save];
}
- (void)photoRotate:(UIRotationGestureRecognizer *)g {
    if (self.locked) return;
    PhotoView *p = (PhotoView *)g.view;
    p.transform = CGAffineTransformRotate(p.transform, g.rotation);
    g.rotation = 0;
    if (g.state == UIGestureRecognizerStateEnded) [self save];
}
- (void)photoTap:(UITapGestureRecognizer *)g { [self select:(PhotoView *)g.view]; [self save]; }

- (void)select:(PhotoView *)p {
    if (self.selected) self.selected.layer.borderColor = [UIColor whiteColor].CGColor;
    self.selected = p;
    if (p) { p.layer.borderColor = [UIColor systemBlueColor].CGColor; [self.world bringSubviewToFront:p]; }
    [self updateUI];
}
- (void)updateUI {
    BOOL any = NO;
    for (UIView *v in self.world.subviews) if ([v isKindOfClass:[PhotoView class]]) { any = YES; break; }
    self.hint.hidden = any || self.liveOn;
}

#pragma mark Delegado de gestos

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    if ([t.view isDescendantOfView:self.toolbar] || [t.view isDescendantOfView:self.panel]) return NO;
    if (g.view == self.view) return ![t.view isKindOfClass:[PhotoView class]];
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return g.view == o.view;
}

#pragma mark Color de fondo

- (void)pickBgColor {
    UIColorPickerViewController *vc = [[UIColorPickerViewController alloc] init];
    vc.delegate = self;
    vc.selectedColor = self.bgColor ?: [UIColor colorWithWhite:0.95 alpha:1];
    [self presentViewController:vc animated:YES completion:nil];
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc {
    self.bgColor = vc.selectedColor;
    self.bgSwatch.backgroundColor = self.bgColor;
    self.view.backgroundColor = self.bgColor;
    [self save];
}
- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)vc {
    self.bgColor = vc.selectedColor;
    self.bgSwatch.backgroundColor = self.bgColor;
    self.view.backgroundColor = self.bgColor;
}

#pragma mark Luz de pantalla (brillo maximo como luz de relleno)

- (void)toggleLight {
    self.lightOn = self.lightSwitch.on;
    self.lightOverlay.hidden = !self.lightOn;
    if (self.lightOn) {
        self.savedBrightness = [UIScreen mainScreen].brightness;
        [UIScreen mainScreen].brightness = 1.0;
        [self.view bringSubviewToFront:self.lightOverlay];
        [self.view bringSubviewToFront:self.panel];
        [self.view bringSubviewToFront:self.toolbar];
    } else {
        [UIScreen mainScreen].brightness = self.savedBrightness;
    }
}

#pragma mark Movimiento en vivo (camara frontal)

- (void)toggleLive {
    if (self.liveOn) { [self stopLive]; return; }
    AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (st == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (granted) [self startLive]; else [self showAlert:@"Sin acceso a la camara" msg:@"Activa el permiso de Camara en Ajustes para usar Movimiento en Vivo."]; });
        }];
    } else if (st == AVAuthorizationStatusAuthorized) {
        [self startLive];
    } else {
        [self showAlert:@"Sin acceso a la camara" msg:@"Activa el permiso de Camara en Ajustes para usar Movimiento en Vivo."];
    }
}

- (void)startLive {
    self.session = [[AVCaptureSession alloc] init];
    self.session.sessionPreset = AVCaptureSessionPreset1280x720;
    AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionFront];
    if (!dev) { [self showAlert:@"Camara no disponible" msg:@"No se encontro la camara frontal."]; return; }
    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
    if (!input) { [self showAlert:@"Error de camara" msg:err.localizedDescription ?: @"No se pudo abrir la camara."]; return; }
    if ([self.session canAddInput:input]) [self.session addInput:input];
    AVCaptureVideoDataOutput *out = [[AVCaptureVideoDataOutput alloc] init];
    out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
    [out setSampleBufferDelegate:self queue:self.camQueue];
    if ([self.session canAddOutput:out]) [self.session addOutput:out];
    AVCaptureConnection *conn = [out connectionWithMediaType:AVMediaTypeVideo];
    if (conn.supportsVideoOrientation) conn.videoOrientation = AVCaptureVideoOrientationPortrait;
    if (conn.supportsVideoMirroring) conn.videoMirrored = YES;

    self.liveOn = YES;
    self.liveView.hidden = NO;
    [self placeLiveView];
    [self.liveBtn setTitle:@"Movimiento En Vivo (ON)" forState:UIControlStateNormal];
    self.liveBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.70 blue:0.35 alpha:1];
    [self updateUI];
    dispatch_async(self.camQueue, ^{ [self.session startRunning]; });
}

- (void)stopLive {
    [self.session stopRunning];
    self.session = nil;
    self.liveOn = NO;
    self.liveView.hidden = YES;
    [self.liveBtn setTitle:@"Movimiento En Vivo" forState:UIControlStateNormal];
    self.liveBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.45 blue:0.15 alpha:1];
    [self updateUI];
}

- (void)placeLiveView {
    if (self.chromaOn) {
        [self.view bringSubviewToFront:self.liveView];   // sobre las fotos: croma recorta y deja ver el panel
        self.liveView.alpha = 1.0;
    } else {
        [self.view insertSubview:self.liveView aboveSubview:self.view]; // fondo
        [self.view sendSubviewToBack:self.liveView];
        self.liveView.alpha = 1.0;
    }
    [self.view bringSubviewToFront:self.lightOverlay];
    [self.view bringSubviewToFront:self.panel];
    [self.view bringSubviewToFront:self.toolbar];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) return;
    CIImage *img = [CIImage imageWithCVPixelBuffer:pb];
    if (self.chromaOn) {
        CIFilter *f = ChromaKeyFilter(self.chromaColor);
        [f setValue:img forKey:kCIInputImageKey];
        CIImage *out = f.outputImage;
        if (out) img = out;
    }
    CGImageRef cg = [self.ciContext createCGImage:img fromRect:img.extent];
    if (!cg) return;
    UIImage *ui = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    dispatch_async(dispatch_get_main_queue(), ^{ self.liveView.image = ui; });
}

#pragma mark Chroma key

- (void)toggleChroma {
    self.chromaOn = self.chromaSwitch.on;
    [self placeLiveView];
    [self save];
}
- (void)pickChromaGreen {
    self.chromaColor = [UIColor colorWithRed:0.10 green:0.80 blue:0.30 alpha:1];
    self.chromaGreenBtn.layer.borderColor = [UIColor whiteColor].CGColor;
    self.chromaBlueBtn.layer.borderColor = [UIColor clearColor].CGColor;
}
- (void)pickChromaBlue {
    self.chromaColor = [UIColor colorWithRed:0.10 green:0.30 blue:0.95 alpha:1];
    self.chromaBlueBtn.layer.borderColor = [UIColor whiteColor].CGColor;
    self.chromaGreenBtn.layer.borderColor = [UIColor clearColor].CGColor;
}

#pragma mark Bloquear panel (Guardar Config)

- (void)toggleLock {
    self.locked = self.lockSwitch.on;
    [self save];
}

#pragma mark Exportar captura a Fotos

- (void)exportSnapshot {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:self.view.bounds format:fmt];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [self.view drawViewHierarchyInRect:self.view.bounds afterScreenUpdates:YES];
    }];
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromImage:img];
    } completionHandler:^(BOOL ok, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:(ok ? @"Guardado" : @"Error") msg:(ok ? @"La captura se guard\u00f3 en Fotos." : (err.localizedDescription ?: @"No se pudo guardar."))];
        });
    }];
}

#pragma mark Menu

- (void)menuTapped {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Men\u00fa" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Agregar foto de galer\u00eda" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self addFromLibrary]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Tomar foto con c\u00e1mara" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self addFromCamera]; }]];
    if (self.selected) [a addAction:[UIAlertAction actionWithTitle:@"Borrar foto seleccionada" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [self deleteSelected]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Centrar panel" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self homeTapped]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.toolbar.items.firstObject;
    [self presentViewController:a animated:YES completion:nil];
}
- (void)homeTapped {
    [UIView animateWithDuration:0.25 animations:^{
        self.boardScale = 1;
        self.world.transform = CGAffineTransformIdentity;
        self.world.center = CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2);
    } completion:^(BOOL f) { [self save]; }];
}
- (void)deleteSelected {
    PhotoView *p = self.selected; if (!p) return;
    [[NSFileManager defaultManager] removeItemAtPath:[self.dir stringByAppendingPathComponent:p.fileName] error:nil];
    [p removeFromSuperview];
    self.selected = nil;
    [self updateUI];
    [self save];
}

#pragma mark Agregar fotos: galeria y camara

- (void)addFromLibrary {
    PHPickerConfiguration *c = [[PHPickerConfiguration alloc] init];
    c.selectionLimit = 0;
    c.filter = [PHPickerFilter imagesFilter];
    PHPickerViewController *v = [[PHPickerViewController alloc] initWithConfiguration:c];
    v.delegate = self;
    [self presentViewController:v animated:YES completion:nil];
}
- (void)addFromCamera {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        [self showAlert:@"C\u00e1mara no disponible" msg:nil]; return;
    }
    UIImagePickerController *p = [[UIImagePickerController alloc] init];
    p.sourceType = UIImagePickerControllerSourceTypeCamera;
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    if (!img) return;
    UIImage *small = [self shrink:img];
    NSString *name = [[[NSUUID UUID] UUIDString] stringByAppendingString:@".jpg"];
    [UIImageJPEGRepresentation(small, 0.88) writeToFile:[self.dir stringByAppendingPathComponent:name] atomically:YES];
    [self addImage:small file:name index:0];
}

- (UIImage *)shrink:(UIImage *)im {
    CGFloat k = MIN(1.0, 1400.0 / MAX(im.size.width, im.size.height));
    CGSize sz = CGSizeMake(floor(im.size.width*k), floor(im.size.height*k));
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:sz format:f] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [im drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    }];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    int k = 0;
    for (PHPickerResult *r in results) {
        if (![r.itemProvider canLoadObjectOfClass:[UIImage class]]) continue;
        int idx = k++;
        [r.itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id<NSItemProviderReading> obj, NSError *err) {
            if (![obj isKindOfClass:[UIImage class]]) return;
            UIImage *img = [self shrink:(UIImage *)obj];
            NSString *name = [[[NSUUID UUID] UUIDString] stringByAppendingString:@".jpg"];
            [UIImageJPEGRepresentation(img, 0.88) writeToFile:[self.dir stringByAppendingPathComponent:name] atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{ [self addImage:img file:name index:idx]; });
        }];
    }
}

#pragma mark Filtros

- (void)filtersTapped {
    if (!self.selected) { [self showAlert:@"Elige una foto" msg:@"Toca una foto del panel y luego Filtros."]; return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Filtros" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *opts = @[@[@"Normal", @""], @[@"Sepia", @"CISepiaTone"], @[@"Blanco y Negro", @"CIPhotoEffectMono"], @[@"Invertido", @"CIColorInvert"], @[@"V\u00edvido", @"CIPhotoEffectChrome"]];
    for (NSArray *o in opts) {
        [a addAction:[UIAlertAction actionWithTitle:o[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self applyFilter:o[1]]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.toolbar.items.lastObject;
    [self presentViewController:a animated:YES completion:nil];
}
- (void)applyFilter:(NSString *)name {
    PhotoView *p = self.selected; if (!p) return;
    NSString *orig = [self.dir stringByAppendingPathComponent:p.fileName];
    UIImage *base = [UIImage imageWithContentsOfFile:orig]; if (!base) return;
    if (name.length == 0) { p.image = base; [self save]; return; }
    CIImage *ci = [CIImage imageWithCGImage:base.CGImage];
    CIFilter *f = [CIFilter filterWithName:name];
    [f setValue:ci forKey:kCIInputImageKey];
    CIImage *out = f.outputImage; if (!out) return;
    CGImageRef cg = [self.ciContext createCGImage:out fromRect:ci.extent];
    if (!cg) return;
    UIImage *res = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    p.image = res;
    [self save];
}

#pragma mark Alertas

- (void)showAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark Guardar / cargar

- (NSString *)statePath { return [self.dir stringByAppendingPathComponent:@"state.plist"]; }

- (void)save {
    NSMutableArray *arr = [NSMutableArray array];
    for (UIView *v in self.world.subviews) {
        if (![v isKindOfClass:[PhotoView class]]) continue;
        PhotoView *p = (PhotoView *)v;
        CGAffineTransform t = p.transform;
        [arr addObject:@{ @"f": p.fileName ?: @"", @"x": @(p.center.x), @"y": @(p.center.y),
                          @"a": @(t.a), @"b": @(t.b), @"c": @(t.c), @"d": @(t.d) }];
    }
    NSMutableDictionary *d = [@{ @"photos": arr, @"cx": @(self.world.center.x), @"cy": @(self.world.center.y),
        @"s": @(self.boardScale), @"locked": @(self.locked), @"chroma": @(self.chromaOn) } mutableCopy];
    if (self.bgColor) d[@"bg"] = HexFromColor(self.bgColor);
    [d writeToFile:[self statePath] atomically:YES];
}

- (void)load {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self statePath]];
    CGPoint c = CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2);
    CGFloat s = 1;
    if (d) {
        s = [d[@"s"] doubleValue]; if (s < 0.1 || s > 6) s = 1;
        c = CGPointMake([d[@"cx"] doubleValue], [d[@"cy"] doubleValue]);
        for (NSDictionary *e in d[@"photos"]) {
            UIImage *img = [UIImage imageWithContentsOfFile:[self.dir stringByAppendingPathComponent:e[@"f"]]];
            if (!img) continue;
            PhotoView *p = [self makePhoto:img file:e[@"f"]];
            p.center = CGPointMake([e[@"x"] doubleValue], [e[@"y"] doubleValue]);
            p.transform = CGAffineTransformMake([e[@"a"] doubleValue], [e[@"b"] doubleValue], [e[@"c"] doubleValue], [e[@"d"] doubleValue], 0, 0);
            [self.world addSubview:p];
        }
        self.locked = [d[@"locked"] boolValue];
        self.lockSwitch.on = self.locked;
        self.chromaOn = [d[@"chroma"] boolValue];
        self.chromaSwitch.on = self.chromaOn;
        if (d[@"bg"]) { self.bgColor = ColorFromHex(d[@"bg"]); self.view.backgroundColor = self.bgColor; self.bgSwatch.backgroundColor = self.bgColor; }
    }
    self.boardScale = s;
    self.world.transform = CGAffineTransformMakeScale(s, s);
    self.world.center = c;
    [self updateUI];
}

@end

#pragma mark - App

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[BoardController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}

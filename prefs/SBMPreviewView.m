//
//  SBMPreviewView.m
//

#import "SBMPreviewView.h"
#import "SBMCommon.h"

#pragma mark - 单个模拟图标

typedef NS_ENUM(NSInteger, SBMIconKind) {
    SBMIconKindTime = 0,
    SBMIconKindSignal,
    SBMIconKindData,
    SBMIconKindWifi,
    SBMIconKindPercent,
    SBMIconKindBattery,
};

@interface SBMPreviewIcon : UIView
@property (nonatomic, assign) SBMIconKind kind;
@property (nonatomic, copy)   NSString   *key;      // 偏好键前缀（标识符）
@property (nonatomic, copy)   NSString   *text;     // 时间 / 5G / 80%
@property (nonatomic, assign) CGSize      idealSize;
@end

@implementation SBMPreviewIcon

- (instancetype)initWithKind:(SBMIconKind)kind key:(NSString *)key text:(NSString *)text {
    if ((self = [super initWithFrame:CGRectZero])) {
        _kind = kind;
        _key  = [key copy];
        _text = [text copy];
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = YES;
        self.idealSize = [self sizeForKind];
    }
    return self;
}

- (CGSize)sizeForKind {
    switch (self.kind) {
        case SBMIconKindTime:    return CGSizeMake(42, 17);
        case SBMIconKindSignal:  return CGSizeMake(18, 12);
        case SBMIconKindData:    return CGSizeMake(22, 15);
        case SBMIconKindWifi:    return CGSizeMake(20, 13);
        case SBMIconKindPercent: return CGSizeMake(30, 15);
        case SBMIconKindBattery: return CGSizeMake(26, 13);
    }
    return CGSizeMake(20, 14);
}

- (void)drawRect:(CGRect)bounds {
    UIColor *solid = UIColor.whiteColor;
    switch (self.kind) {

        case SBMIconKindSignal: {
            CGFloat h[4] = { 4.0, 6.5, 9.0, 11.5 };
            CGFloat w = 3.0, gap = 2.0;
            for (int i = 0; i < 4; i++) {
                CGRect r = CGRectMake(i * (w + gap), CGRectGetHeight(bounds) - h[i], w, h[i]);
                [solid setFill];
                [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:1.2] fill];
            }
            break;
        }

        case SBMIconKindWifi: {
            CGFloat w = CGRectGetWidth(bounds);
            CGPoint c = CGPointMake(w / 2.0, CGRectGetHeight(bounds) + 1.0);
            for (int i = 0; i < 3; i++) {
                CGFloat r = 4.0 + i * 3.0;
                UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:c radius:r
                                    startAngle:M_PI * 1.25 endAngle:M_PI * 1.75 clockwise:YES];
                arc.lineWidth = 2.0;
                arc.lineCapStyle = kCGLineCapRound;
                [solid setStroke];
                [arc stroke];
            }
            UIBezierPath *dot = [UIBezierPath bezierPathWithArcCenter:CGPointMake(c.x, c.y - 1.2)
                                    radius:1.3 startAngle:0 endAngle:M_PI * 2 clockwise:YES];
            [solid setFill];
            [dot fill];
            break;
        }

        case SBMIconKindBattery: {
            CGFloat nubW = 2.5;
            CGRect body = CGRectMake(0, 1.0, CGRectGetWidth(bounds) - nubW - 1.0, CGRectGetHeight(bounds) - 2.0);
            UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:3.2];
            outline.lineWidth = 1.2;
            [[solid colorWithAlphaComponent:0.72] setStroke];
            [outline stroke];

            CGRect fillRect = CGRectInset(body, 2.0, 2.0);
            fillRect.size.width *= 0.72;
            [[solid colorWithAlphaComponent:0.95] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:fillRect cornerRadius:1.4] fill];

            CGRect nub = CGRectMake(CGRectGetMaxX(body) + 1.0, CGRectGetMidY(bounds) - 2.5, nubW, 5.0);
            [[solid colorWithAlphaComponent:0.55] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:nub cornerRadius:1.2] fill];
            break;
        }

        case SBMIconKindTime:
        case SBMIconKindData:
        case SBMIconKindPercent: {
            NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
            ps.alignment = NSTextAlignmentCenter;
            UIFont *font = [UIFont systemFontOfSize:(self.kind == SBMIconKindTime ? 13.5 : 11.5)
                                             weight:UIFontWeightSemibold];
            NSDictionary *attrs = @{ NSFontAttributeName: font,
                                     NSForegroundColorAttributeName: solid,
                                     NSParagraphStyleAttributeName: ps };
            [self.text ?: @"" drawInRect:bounds withAttributes:attrs];
            break;
        }
    }
}

@end

#pragma mark - 预览容器

@implementation SBMPreviewView {
    UIView                       *_bar;
    UILabel                      *_titleLabel;
    UILabel                      *_hintLabel;
    NSMutableArray<SBMPreviewIcon *> *_icons;
    NSDictionary<NSString *, NSString *> *_keys;
    CFTimeInterval                _lastWrite;
    CGFloat                       _dragStartX;
    CGFloat                       _dragStartY;
}

- (instancetype)initWithWidth:(CGFloat)width keys:(NSDictionary<NSString *, NSString *> *)catToKey {
    if ((self = [super initWithFrame:CGRectMake(0, 0, width, 112)])) {
        _keys = [catToKey copy];
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;

        _titleLabel = [UILabel new];
        _titleLabel.text = @"实时预览 ―― 按住图标直接拖动";
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = UIColor.secondaryLabelColor;
        [self addSubview:_titleLabel];

        _bar = [UIView new];
        _bar.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
        _bar.layer.cornerRadius = 12.0;
        _bar.layer.borderWidth = 0.5;
        _bar.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:1.0].CGColor;
        [self addSubview:_bar];

        _icons = [NSMutableArray array];
        [self addIcon:SBMIconKindTime    cat:@"time"    text:@"9:41"];
        [self addIcon:SBMIconKindSignal  cat:@"signal"  text:nil];
        [self addIcon:SBMIconKindData    cat:@"data"    text:@"5G"];
        [self addIcon:SBMIconKindWifi    cat:@"wifi"    text:nil];
        [self addIcon:SBMIconKindPercent cat:@"percent" text:@"80%"];
        [self addIcon:SBMIconKindBattery cat:@"battery" text:nil];

        _hintLabel = [UILabel new];
        _hintLabel.text = @"拖动 = 直接调位置（松手即生效）　·　双击图标 = 复位该项";
        _hintLabel.font = [UIFont systemFontOfSize:11];
        _hintLabel.textColor = UIColor.tertiaryLabelColor;
        [self addSubview:_hintLabel];

        [self reload];
    }
    return self;
}

- (void)addIcon:(SBMIconKind)kind cat:(NSString *)cat text:(NSString *)text {
    SBMPreviewIcon *icon = [[SBMPreviewIcon alloc] initWithKind:kind key:_keys[cat] text:text];
    icon.tag = kind;
    [_bar addSubview:icon];
    [_icons addObject:icon];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [icon addGestureRecognizer:pan];

    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    dbl.numberOfTapsRequired = 2;
    [icon addGestureRecognizer:dbl];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    _titleLabel.frame = CGRectMake(18, 4, w - 36, 18);
    _bar.frame = CGRectMake(16, 28, w - 32, 48);
    _hintLabel.frame = CGRectMake(18, 82, w - 36, 15);

    CGFloat barW = CGRectGetWidth(_bar.bounds);
    CGFloat barH = CGRectGetHeight(_bar.bounds);

    // 左侧：时间
    for (SBMPreviewIcon *icon in _icons) {
        if (icon.kind == SBMIconKindTime) {
            icon.frame = CGRectMake(30, (barH - icon.idealSize.height) / 2.0,
                                    icon.idealSize.width, icon.idealSize.height);
        }
    }
    // 右侧：信号 → 数据 → Wi-Fi → 百分比 → 电池（整体右对齐）
    NSArray *order = @[ @(SBMIconKindBattery), @(SBMIconKindPercent), @(SBMIconKindWifi),
                        @(SBMIconKindData), @(SBMIconKindSignal) ];
    CGFloat right = barW - 14.0;
    for (NSNumber *n in order) {
        for (SBMPreviewIcon *icon in _icons) {
            if ((NSInteger)icon.kind != n.integerValue) continue;
            CGFloat iw = icon.idealSize.width, ih = icon.idealSize.height;
            icon.frame = CGRectMake(right - iw, (barH - ih) / 2.0, iw, ih);
            right -= (iw + 5.0);
        }
    }
    [self applyOffsetsToIcons];
}

// ---- 读偏好 → 更新每个图标的 transform ----

- (void)applyOffsetsToIcons {
    for (SBMPreviewIcon *icon in _icons) {
        CGFloat dx = 0, dy = 0;
        if (icon.key.length) {
            dx = SBMOffset(icon.key, @"x");
            dy = SBMOffset(icon.key, @"y");
        }
        icon.transform = CGAffineTransformMakeTranslation(dx, dy);
    }
}

- (void)reload {
    [self applyOffsetsToIcons];
}

// ---- 拖动 ----

- (void)handlePan:(UIPanGestureRecognizer *)g {
    SBMPreviewIcon *icon = (SBMPreviewIcon *)g.view;
    if (![icon isKindOfClass:SBMPreviewIcon.class] || !icon.key.length) return;

    CGPoint t = [g translationInView:self];

    if (g.state == UIGestureRecognizerStateBegan) {
        _dragStartX = SBMOffset(icon.key, @"x");
        _dragStartY = SBMOffset(icon.key, @"y");
        _lastWrite  = 0;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat nx = MAX(-60.0, MIN(60.0, _dragStartX + t.x));
        CGFloat ny = MAX(-25.0, MIN(25.0, _dragStartY + t.y));
        icon.transform = CGAffineTransformMakeTranslation(nx, ny);
        [self writeOffset:icon x:nx y:ny throttled:YES];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        CGFloat nx = MAX(-60.0, MIN(60.0, _dragStartX + t.x));
        CGFloat ny = MAX(-25.0, MIN(25.0, _dragStartY + t.y));
        icon.transform = CGAffineTransformMakeTranslation(nx, ny);
        [self writeOffset:icon x:nx y:ny throttled:NO];
        [self.delegate previewDidFinishDragging:self];
    }
}

- (void)writeOffset:(SBMPreviewIcon *)icon x:(CGFloat)x y:(CGFloat)y throttled:(BOOL)throttled {
    if (!icon.key.length) return;
    if (throttled) {
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - _lastWrite < 0.08) return;   // ≈12Hz，足够跟手又不刷爆偏好落盘
        _lastWrite = now;
        SBMSetOffset(icon.key, @"x", round(x), YES);
        SBMSetOffset(icon.key, @"y", round(y), YES);
    } else {
        SBMSetOffset(icon.key, @"x", round(x), YES);
        SBMSetOffset(icon.key, @"y", round(y), YES);
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    SBMPreviewIcon *icon = (SBMPreviewIcon *)g.view;
    if (![icon isKindOfClass:SBMPreviewIcon.class] || !icon.key.length) return;
    icon.transform = CGAffineTransformIdentity;
    SBMSetOffset(icon.key, @"x", 0, YES);
    SBMSetOffset(icon.key, @"y", 0, YES);
    [self.delegate previewDidFinishDragging:self];
}

@end

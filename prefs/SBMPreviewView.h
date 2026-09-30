//
//  SBMPreviewView.h — 设置页顶部的「可拖动实时预览」
//
//  这不是一张示意图：它用的就是插件运行时那套 transform 偏移逻辑，
//  拖到哪儿，真实状态栏上的图标就会跟到哪儿。
//

#import <UIKit/UIKit.h>

@class SBMPreviewView;

@protocol SBMPreviewViewDelegate <NSObject>
// 一次拖动结束后回调（用于刷新列表里的滑块数值）
- (void)previewDidFinishDragging:(SBMPreviewView *)view;
@end

@interface SBMPreviewView : UIView

@property (nonatomic, weak) id<SBMPreviewViewDelegate> delegate;

// catToKey: @{ @"signal": @"cellularBars", @"data": @"dataNetwork", ... }
- (instancetype)initWithWidth:(CGFloat)width keys:(NSDictionary<NSString *, NSString *> *)catToKey;

// 重新从偏好读取数值并刷新预览
- (void)reload;

@end

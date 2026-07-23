/*
 * TrollShot 使用的私有 UIScreen 方法，用于获取像素级精确屏幕尺寸。
 */

#import <UIKit/UIKit.h>

@interface UIScreen (Private)
- (CGRect)_unjailedReferenceBoundsInPixels;
@end

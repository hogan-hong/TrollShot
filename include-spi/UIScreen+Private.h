/*
 * Private UIScreen methods used by TrollShot for pixel-accurate screen dimensions.
 */

#import <UIKit/UIKit.h>

@interface UIScreen (Private)
- (CGRect)_unjailedReferenceBoundsInPixels;
@end

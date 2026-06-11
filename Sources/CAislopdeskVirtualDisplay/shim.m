// SPM requires at least one source file in a clang target; this just anchors the module so the
// public header in include/ is compiled. The CGVirtualDisplay* classes resolve at link time from
// CoreGraphics.framework (public framework — no dlopen, no extra linker flags).
#import "CGVirtualDisplayPrivate.h"

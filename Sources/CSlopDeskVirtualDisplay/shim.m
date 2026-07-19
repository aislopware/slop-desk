// SPM requires at least one source file in a clang target; this just anchors the module so the
// public header in include/ is compiled. The CGVirtualDisplay* classes resolve at link time from
// CoreGraphics.framework (public framework — no dlopen, no extra linker flags), but only the
// FRAMEWORK is public: the four classes themselves are private/undocumented, so their
// `@interface`s are `weak_import`ed (see the header) rather than hard-linked — a future OS
// removing/renaming one degrades to nil at runtime instead of failing dyld's symbol bind.
#import "CGVirtualDisplayPrivate.h"

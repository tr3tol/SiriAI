#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <objc/message.h>

#define kBundlePath "/var/jb/Library/PreferenceBundles/SiriAIPreferences.bundle"
#define kDomain     "com.tr3tol.siriai"

static void *kSpecifiersKey = &kSpecifiersKey;

static id SAStr(const char *utf8) {
	return ((id (*)(id, SEL, const char *))objc_msgSend)(
		(id)objc_getClass("NSString"), sel_getUid("stringWithUTF8String:"), utf8);
}

static id SASend(id target, const char *selector) {
	return ((id (*)(id, SEL))objc_msgSend)(target, sel_getUid(selector));
}

static id SASend1(id target, const char *selector, id arg) {
	return ((id (*)(id, SEL, id))objc_msgSend)(target, sel_getUid(selector), arg);
}

static BOOL SAEquals(id a, const char *b) {
	if (!a) return NO;
	return ((BOOL (*)(id, SEL, id))objc_msgSend)(a, sel_getUid("isEqualToString:"), SAStr(b));
}

// PSEditableTableCell moves to the next field on Return. The original runs for specifiers
// outside this domain so other panes keep their behaviour.
static BOOL (*SAOriginalShouldReturn)(id, SEL, id);

static BOOL SAShouldReturn(id self, SEL _cmd, id textField) {
	id specifier = SASend(self, "specifier");
	if (specifier && SAEquals(SASend1(specifier, "propertyForKey:", SAStr("defaults")), kDomain)) {
		((void (*)(id, SEL))objc_msgSend)(textField, sel_getUid("resignFirstResponder"));
		return NO;
	}
	if (SAOriginalShouldReturn) return SAOriginalShouldReturn(self, _cmd, textField);
	return YES;
}

static void SAFixReturnKey(void) {
	Class cell = objc_getClass("PSEditableTableCell");
	if (!cell) return;

	Method m = class_getInstanceMethod(cell, sel_getUid("textFieldShouldReturn:"));
	if (!m || SAOriginalShouldReturn) return;

	SAOriginalShouldReturn = (BOOL (*)(id, SEL, id))method_getImplementation(m);
	method_setImplementation(m, (IMP)SAShouldReturn);
}

// PSListController clears _specifiers when the page is left, so write it back every call
// or the rows vanish on return.
static void SAPublish(id self, id specifiers) {
	Ivar ivar = class_getInstanceVariable(objc_getClass("PSListController"), "_specifiers");
	if (ivar && object_getIvar(self, ivar) != specifiers) {
		SASend(specifiers, "retain");
		object_setIvar(self, ivar, specifiers);
	}
}

static id SARootSpecifiers(id self, SEL _cmd) {
	id cached = objc_getAssociatedObject(self, kSpecifiersKey);
	if (cached) { SAPublish(self, cached); return cached; }

	id bundle = ((id (*)(id, SEL, id))objc_msgSend)(
		(id)objc_getClass("NSBundle"), sel_getUid("bundleWithPath:"), SAStr(kBundlePath));

	id specifiers = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
		self, sel_getUid("loadSpecifiersFromPlistName:target:bundle:"),
		SAStr("Root"), self, bundle);

	objc_setAssociatedObject(self, kSpecifiersKey, specifiers,
	                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	SAPublish(self, specifiers);
	return specifiers;
}

// Built through the runtime rather than @interface: this toolchain corrupts compile-time
// class metadata in the arm64e slice.
__attribute__((constructor))
static void SARegisterControllers(void) {
	if (objc_getClass("SiriAIRootListController")) return;

	Class base = objc_getClass("PSListController");
	if (!base) return;

	Class page = objc_allocateClassPair(base, "SiriAIRootListController", 0);
	if (!page) return;

	class_addMethod(page, sel_getUid("specifiers"), (IMP)SARootSpecifiers, "@@:");
	objc_registerClassPair(page);

	SAFixReturnKey();
}

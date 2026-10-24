#import <UIKit/UIKit.h>
#import <pthread.h>

#import "../SiriAICore.h"

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

// Runs the same request Siri would, model by model, and reports each outcome in an alert.
// The alert is updated in place rather than replaced, which would need a completion block.

static void *kAlertKey = &kAlertKey;

static uint64_t sa_notify_get(const char *name) {
	int token;
	uint64_t v = 0;
	if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return 0;
	notify_get_state(token, &v);
	notify_cancel(token);
	return v;
}

static void sa_line(NSMutableString *r, BOOL ok, const char *text) {
	[r appendFormat:sa_str("\n%s %s"), ok ? "✓" : "✗", text];
}

// What the tweak last saw inside Siri. Each step depends on the one before, so the first
// cross marks where it stops.
static NSString *sa_siri_report(void) {
	uint64_t word = sa_notify_get(kStatusName);
	uint64_t st = word & 0xFFFFFFFFULL;
	if (!(st & SA_ST_LOADED))
		return sa_str("Siri: no status. The tweak is not running in Siri: it was not "
		              "loaded, or Siri has not started since the install.");

	char proc[9];
	sa_unpack8(sa_notify_get(kStatusProc), proc);
	long age = (long)time(NULL) - (long)(word >> 32);

	NSMutableString *r = [NSMutableString string];
	[r appendFormat:sa_str("Siri (%s, updated %ld s ago):"), proc, age];
	sa_line(r, YES, "tweak loaded");
	sa_line(r, st & SA_ST_CONV_CLASS, "AFConversation class");
	sa_line(r, st & SA_ST_VIEW_CLASS, "SiriSharedUICompactViewModelController class");
	sa_line(r, st & SA_ST_QUESTION, "question heard");
	sa_line(r, st & SA_ST_ITEMS, "reply received");
	if (st & SA_ST_DISABLED) sa_line(r, NO, "tweak switched off");
	sa_line(r, st & SA_ST_ACE, "reply content readable");
	sa_line(r, st & SA_ST_IDENT, "reply identifiers");

	for (int i = 0; i < kStatusIdents; i++) {
		char a[9], b[9], name[96];
		snprintf(name, sizeof(name), "%s%d", kStatusIdent, 2 * i);
		sa_unpack8(sa_notify_get(name), a);
		snprintf(name, sizeof(name), "%s%d", kStatusIdent, 2 * i + 1);
		sa_unpack8(sa_notify_get(name), b);
		if (a[0]) [r appendFormat:sa_str("\n    %s%s"), a, b];
	}

	sa_line(r, st & SA_ST_MATCH, "web search reply recognised");
	if (st & SA_ST_MATCH) {
		sa_line(r, st & SA_ST_STARTED, "request sent");
		if (st & SA_ST_ANSWERED) sa_line(r, YES, "answer received");
		if (st & SA_ST_FAILED) sa_line(r, NO, "request failed");
		if (st & SA_ST_TIMEOUT) sa_line(r, NO, "timed out");
		sa_line(r, st & SA_ST_REPLACED, "reply replaced");
	}
	return r;
}

static NSString *sa_test_report(void) {
	NSMutableString *report = [NSMutableString string];
	[report appendString:sa_siri_report()];
	[report appendString:sa_str("\n\n")];

	NSString *key = sa_pref_str("apiKey", "");
	if ([key length] == 0) {
		[report appendString:sa_str("No API key set.")];
		return report;
	}

	NSString *base = sa_base_url();
	BOOL openrouter = sa_is_openrouter(base);
	NSArray *chain = sa_model_chain(openrouter);
	if ([chain count] == 0) {
		[report appendString:sa_str("No model set. The default models are OpenRouter ids and "
		                            "only apply with an OpenRouter base URL.")];
		return report;
	}

	const char *question = [sa_pref_str("language", "ru") isEqualToString:sa_str("en")]
		? "Hello, can you hear me?" : "Привет, ты меня слышишь?";
	double timeout = sa_timeout();
	double share = timeout / (double)[chain count];

	[report appendString:base];
	for (NSString *model in chain) {
		char err[512] = "";
		BOOL fatal = NO;
		double started = CFAbsoluteTimeGetCurrent();
		char *answer = sa_ask_model(question, key, base, openrouter, model, timeout, &fatal,
			err, sizeof(err));
		double took = CFAbsoluteTimeGetCurrent() - started;

		if (answer) {
			[report appendFormat:sa_str("\n\n✓ %@, %.1f s\n%@"), model, took, sa_str(answer)];
			if (took > share)
				[report appendFormat:sa_str("\nSlower than its %.1f s share of the timeout."),
					share];
			free(answer);
		} else {
			[report appendFormat:sa_str("\n\n✗ %@"), sa_str(err)];
		}
		if (fatal) {
			[report appendString:sa_str("\n\nStopped: the key or the account was rejected.")];
			break;
		}
	}
	return report;
}

static void *sa_test_worker(void *arg) {
	@autoreleasepool {
		id controller = (__bridge_transfer id)arg;
		NSString *report = sa_test_report();
		[controller performSelectorOnMainThread:sel_getUid("sa_showTestResult:")
			withObject:report waitUntilDone:NO];
	}
	return NULL;
}

void SATestConnection(id controller) {
	if (objc_getAssociatedObject(controller, kAlertKey)) return;

	// Commits a field still being edited, so the test uses what is on screen.
	[[controller view] endEditing:YES];

	UIAlertController *alert = [UIAlertController alertControllerWithTitle:sa_str("Testing…")
		message:sa_str("Sending a question to each model.")
		preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:sa_str("OK")
		style:UIAlertActionStyleCancel handler:nil]];
	objc_setAssociatedObject(controller, kAlertKey, alert, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	[controller presentViewController:alert animated:YES completion:nil];

	pthread_t t;
	if (pthread_create(&t, NULL, sa_test_worker, (__bridge_retained void *)controller) != 0) {
		CFRelease((__bridge CFTypeRef)controller);
		objc_setAssociatedObject(controller, kAlertKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[alert setTitle:sa_str("Test failed")];
		[alert setMessage:sa_str("Could not start a thread.")];
		return;
	}
	pthread_detach(t);
}

void SAShowTestResult(id controller, id report) {
	UIAlertController *alert = objc_getAssociatedObject(controller, kAlertKey);
	objc_setAssociatedObject(controller, kAlertKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	if (alert && [alert presentingViewController]) {
		[alert setTitle:sa_str("SiriAI")];
		[alert setMessage:report];
		return;
	}

	// Dismissed while waiting: show the result anew.
	alert = [UIAlertController alertControllerWithTitle:sa_str("SiriAI") message:report
		preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:sa_str("OK")
		style:UIAlertActionStyleCancel handler:nil]];
	[controller presentViewController:alert animated:YES completion:nil];
}

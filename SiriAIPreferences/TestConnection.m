#import <UIKit/UIKit.h>
#import <pthread.h>

#import "../SiriAICore.h"

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

// Runs the same request Siri would, model by model, and reports each outcome in an alert.
// The alert is updated in place rather than replaced, which would need a completion block.

static void *kAlertKey = &kAlertKey;

static NSString *sa_test_report(void) {
	NSMutableString *report = [NSMutableString string];

	NSString *key = sa_pref_str("apiKey", "");
	if ([key length] == 0) return sa_str("No API key set.");

	NSString *base = sa_base_url();
	BOOL openrouter = sa_is_openrouter(base);
	NSArray *chain = sa_model_chain(openrouter);
	if ([chain count] == 0)
		return sa_str("No model set. The default models are OpenRouter ids and only apply "
		              "with an OpenRouter base URL.");

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

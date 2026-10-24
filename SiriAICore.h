// Preferences and the model request, shared by the tweak and the settings pane so the
// connection test there exercises exactly what Siri runs.
//
// No @"" literals, ObjC collection literals, blocks or @interface: the arm64e slice built
// by this toolchain uses the old ABI, which only plain C calls and message sends survive.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <os/log.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// Each includer uses only part of this file.
#pragma clang diagnostic ignored "-Wunused-function"

#define kPrefDomain "com.tr3tol.siriai"

#define kDefaultBaseURL "https://openrouter.ai/api/v1"
// Instruction-tuned and small: reasoning models put their thinking in the answer, and
// the bigger free models hit the shared quota first.
#define kDefaultModel   "google/gemma-4-26b-a4b-it:free"
#define kDefaultBackup  "liquid/lfm-2.5-2.6b:free"

// Router across every free model. May land on a slow one, so it goes last.
#define kDefaultLast    "openrouter/free"

// Answers are spoken: TTS reads asterisks and bullets out loud.
#define kPromptRU "Ты голосовой помощник. Отвечай кратко и по существу: одним предложением, при необходимости двумя. Без вступлений, без повтора вопроса, без списков, без разметки, без ссылок, без эмодзи. Не выдумывай факты: если не знаешь или не уверен, скажи об этом прямо. Отвечай по-русски."
#define kPromptEN "You are a voice assistant. Answer briefly and to the point: one sentence, two if the question needs it. No preamble, no restating the question, no lists, no markup, no links, no emoji. Never invent facts: say plainly when you do not know or are unsure. Answer in English."
#define kPromptAuto "You are a voice assistant. Answer briefly and to the point: one sentence, two if the question needs it. No preamble, no restating the question, no lists, no markup, no links, no emoji. Never invent facts: say plainly when you do not know or are unsure. Always answer in the language the question was asked in."

// Never nil: invalid UTF-8 would otherwise reach a collection setter and throw.
static NSString *sa_str(const char *utf8) {
	NSString *s = utf8 ? [NSString stringWithUTF8String:utf8] : nil;
	return s ? s : [NSString string];
}

// strlcpy that never splits a multi-byte character, so the copy stays valid UTF-8.
static void sa_copy_utf8(char *dst, const char *src, size_t size) {
	if (size == 0) return;
	size_t n = strlen(src);
	if (n >= size) {
		n = size - 1;
		while (n > 0 && ((unsigned char)src[n] & 0xC0) == 0x80) n--;
	}
	memcpy(dst, src, n);
	dst[n] = '\0';
}

// A long-lived process keeps its own copy of another app's domain and does not see edits
// made in Settings until told to reload it.
static void sa_prefs_sync(void) {
	CFStringRef d = CFStringCreateWithCString(kCFAllocatorDefault, kPrefDomain, kCFStringEncodingUTF8);
	CFPreferencesAppSynchronize(d);
	CFRelease(d);
}

// cfprefsd is unreachable from the Siri sandbox, so the plist is read directly.
static id sa_pref_obj(const char *key) {
	CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
	CFStringRef d = CFStringCreateWithCString(kCFAllocatorDefault, kPrefDomain, kCFStringEncodingUTF8);
	CFPropertyListRef v = CFPreferencesCopyAppValue(k, d);
	CFRelease(k);
	CFRelease(d);
	if (v) return (__bridge_transfer id)v;

	static const char *paths[] = {
		"/var/jb/var/mobile/Library/Preferences/" kPrefDomain ".plist",
		"/var/mobile/Library/Preferences/" kPrefDomain ".plist",
		NULL
	};
	for (int i = 0; paths[i]; i++) {
		NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:sa_str(paths[i])];
		if (![plist isKindOfClass:[NSDictionary class]]) continue;
		id value = [plist objectForKey:sa_str(key)];
		if (value) return value;
	}
	return nil;
}

// A pasted key or model id often carries a trailing space or newline, which the server
// rejects as a different key or an unknown model.
static NSString *sa_trim(id v) {
	if (![v isKindOfClass:[NSString class]]) return nil;
	return [(NSString *)v stringByTrimmingCharactersInSet:
		[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *sa_pref_str(const char *key, const char *fallback) {
	NSString *v = sa_trim(sa_pref_obj(key));
	if ([v length] > 0) return v;
	return sa_str(fallback);
}

static BOOL sa_pref_bool(const char *key, BOOL fallback) {
	id v = sa_pref_obj(key);
	if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]])
		return [v boolValue];
	return fallback;
}

static double sa_pref_num(const char *key, double fallback) {
	id v = sa_pref_obj(key);
	if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]) {
		double d = [v doubleValue];
		if (d > 0) return d;
	}
	return fallback;
}

// Bounds how long the main thread is held.
static double sa_timeout(void) {
	double t = sa_pref_num("timeout", 8.0);
	if (t < 3.0) t = 3.0;
	if (t > 12.0) t = 12.0;
	return t;
}

static int sa_max_tokens(void) {
	double n = sa_pref_num("maxTokens", 160);
	if (n < 16) n = 16;
	if (n > 2048) n = 2048;
	return (int)n;
}

// Some models emit their thinking before </think>. Keep only what follows. Thinking cut off
// by the length limit has no closing tag and nothing after it worth speaking.
static void sa_strip_reasoning(char *s) {
	static const char *marker = "</think>";
	char *end = strstr(s, marker);
	if (!end) {
		const char *p = s;
		while (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') p++;
		if (strncmp(p, "<think>", 7) == 0) s[0] = '\0';
		return;
	}

	char *answer = end + strlen(marker);
	memmove(s, answer, strlen(answer) + 1);
}

// Drops ASCII markup only. UTF-8 continuation bytes have the high bit set, so Cyrillic
// is untouched. '#' goes only where it opens a word, so headings vanish but C# stays.
static void sa_clean(char *s) {
	char *out = s;
	int space = 1;

	for (char *in = s; *in; in++) {
		unsigned char c = (unsigned char)*in;
		if (c == '*' || c == '`' || c == '_') continue;
		if (c == '#' && space) continue;
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
			if (!space) { *out++ = ' '; space = 1; }
			continue;
		}
		*out++ = (char)c;
		space = 0;
	}

	while (out > s && out[-1] == ' ') out--;
	*out = '\0';
}

// NSString rather than strcasecmp: C case folding only knows ASCII.
static NSString *sa_trigger_prompt(const char *question) {
	if (!sa_pref_bool("triggerEnabled", NO)) return nil;

	NSString *prompt = sa_pref_str("triggerPrompt", "");
	if ([prompt length] == 0) return nil;

	NSString *asked = sa_str(question);
	NSArray *words = [sa_pref_str("triggerWords", "") componentsSeparatedByString:sa_str(",")];
	NSCharacterSet *blank = [NSCharacterSet whitespaceAndNewlineCharacterSet];

	for (NSString *raw in words) {
		NSString *word = [raw stringByTrimmingCharactersInSet:blank];
		if ([word length] == 0) continue;
		if ([asked rangeOfString:word options:NSCaseInsensitiveSearch].location != NSNotFound)
			return prompt;
	}
	return nil;
}

static NSString *sa_prompt_for(const char *question) {
	NSString *triggered = sa_trigger_prompt(question);
	if (triggered) return triggered;

	NSString *prompt = sa_pref_str("systemPrompt", "");
	if ([prompt length] > 0) return prompt;

	NSString *lang = sa_pref_str("language", "ru");
	const char *canned = kPromptAuto;
	if ([lang isEqualToString:sa_str("ru")]) canned = kPromptRU;
	else if ([lang isEqualToString:sa_str("en")]) canned = kPromptEN;
	return sa_str(canned);
}

// Accepts the root, the /v1 root or the full endpoint as pasted from provider docs.
static NSString *sa_base_url(void) {
	NSString *base = sa_pref_str("baseURL", kDefaultBaseURL);
	if ([base rangeOfString:sa_str("://")].location == NSNotFound)
		base = [sa_str("https://") stringByAppendingString:base];
	while ([base hasSuffix:sa_str("/")])
		base = [base substringToIndex:[base length] - 1];
	if ([base hasSuffix:sa_str("/chat/completions")])
		base = [base substringToIndex:[base length] - strlen("/chat/completions")];
	return base;
}

static BOOL sa_host_is(NSString *base, const char *domain) {
	NSString *host = [[NSURL URLWithString:base] host];
	if (!host) return NO;
	return [host rangeOfString:sa_str(domain)
		options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// The default model ids and the reasoning parameter are OpenRouter's own. Elsewhere the ids
// do not exist, and strict servers may reject the request outright over the unknown field.
static BOOL sa_is_openrouter(NSString *base) {
	return sa_host_is(base, "openrouter.ai");
}

// An untouched field falls back to the OpenRouter default, on OpenRouter only. A backup
// field cleared on purpose stays off.
static NSString *sa_pref_model(const char *key, const char *fallback, BOOL primary,
                               BOOL openrouter) {
	NSString *v = sa_trim(sa_pref_obj(key));
	if ([v length] > 0) return v;
	if (v && !primary) return nil;
	return openrouter ? sa_str(fallback) : nil;
}

static NSArray *sa_model_chain(BOOL openrouter) {
	NSMutableArray *chain = [NSMutableArray array];
	const char *keys[]      = { "model",       "backupModel",  "lastModel"  };
	const char *fallbacks[] = { kDefaultModel, kDefaultBackup, kDefaultLast };

	for (int i = 0; i < 3; i++) {
		NSString *model = sa_pref_model(keys[i], fallbacks[i], i == 0, openrouter);
		if ([model length] > 0 && ![chain containsObject:model])
			[chain addObject:model];
	}
	return chain;
}

// Providers put the reason in error.message, error, or message.
static NSString *sa_error_message(NSData *data) {
	if (!data) return nil;
	id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	if ([json isKindOfClass:[NSDictionary class]]) {
		id err = [json objectForKey:sa_str("error")];
		if ([err isKindOfClass:[NSDictionary class]])
			err = [err objectForKey:sa_str("message")];
		if (![err isKindOfClass:[NSString class]])
			err = [json objectForKey:sa_str("message")];
		if ([err isKindOfClass:[NSString class]]) {
			NSString *msg = err;
			NSRange cut = [msg rangeOfString:sa_str(" (request_id")];
			if (cut.location != NSNotFound) msg = [msg substringToIndex:cut.location];
			return msg;
		}
	}
	NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if ([text length] > 160) text = [text substringToIndex:160];
	return text;
}

static void sa_fail(char *err, size_t errlen, NSString *model, NSString *reason) {
	NSString *line = [NSString stringWithFormat:sa_str("%@: %@"), model, reason];
	const char *utf8 = [line UTF8String];
	os_log(OS_LOG_DEFAULT, "[SiriAI] %{public}s", utf8 ? utf8 : "?");
	if (err) sa_copy_utf8(err, utf8 ? utf8 : "", errlen);
}

// fatal: a rejected key or an empty account, which no other model survives either.
// err receives a one-line reason on failure.
static char *sa_ask_model(const char *question, NSString *key, NSString *base, BOOL openrouter,
                          NSString *model, double budget, BOOL *fatal,
                          char *err, size_t errlen) {
	*fatal = NO;

	NSURL *url = [NSURL URLWithString:[base stringByAppendingString:sa_str("/chat/completions")]];
	if (!url) {
		sa_fail(err, errlen, model, sa_str("invalid base URL"));
		*fatal = YES;
		return NULL;
	}

	NSMutableDictionary *sys = [NSMutableDictionary dictionary];
	[sys setObject:sa_str("system") forKey:sa_str("role")];
	[sys setObject:sa_prompt_for(question) forKey:sa_str("content")];

	NSMutableDictionary *usr = [NSMutableDictionary dictionary];
	[usr setObject:sa_str("user") forKey:sa_str("role")];
	[usr setObject:sa_str(question) forKey:sa_str("content")];

	NSMutableArray *messages = [NSMutableArray array];
	[messages addObject:sys];
	[messages addObject:usr];

	NSMutableDictionary *body = [NSMutableDictionary dictionary];
	[body setObject:model forKey:sa_str("model")];
	[body setObject:messages forKey:sa_str("messages")];
	[body setObject:[NSNumber numberWithInt:sa_max_tokens()] forKey:sa_str("max_tokens")];

	// Otherwise reasoning ends up in content and gets spoken. Other providers either return
	// it in a separate field or inline it before </think>, which is stripped below.
	if (openrouter) {
		NSMutableDictionary *reasoning = [NSMutableDictionary dictionary];
		[reasoning setObject:[NSNumber numberWithBool:YES] forKey:sa_str("exclude")];
		[body setObject:reasoning forKey:sa_str("reasoning")];
	}

	// DeepSeek thinks by default: the reasoning uses up max_tokens, leaves content empty and
	// takes longer than the timeout.
	if (sa_host_is(base, "deepseek.com")) {
		NSMutableDictionary *thinking = [NSMutableDictionary dictionary];
		[thinking setObject:sa_str("disabled") forKey:sa_str("type")];
		[body setObject:thinking forKey:sa_str("thinking")];
	}

	NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
	if (!payload) {
		sa_fail(err, errlen, model, sa_str("could not encode the request"));
		return NULL;
	}

	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
	[req setHTTPMethod:sa_str("POST")];
	[req setValue:sa_str("application/json") forHTTPHeaderField:sa_str("Content-Type")];
	[req setValue:[sa_str("Bearer ") stringByAppendingString:key]
		forHTTPHeaderField:sa_str("Authorization")];
	[req setHTTPBody:payload];
	[req setTimeoutInterval:budget];

	// Synchronous: no completion block, so no helper process is needed.
	NSURLResponse *response = nil;
	NSError *error = nil;
	NSData *data = [NSURLConnection sendSynchronousRequest:req
		returningResponse:&response error:&error];
	if (!data) {
		NSString *why = [error localizedDescription];
		sa_fail(err, errlen, model, why ? why : sa_str("request failed"));
		return NULL;
	}

	long status = [response respondsToSelector:sel_getUid("statusCode")]
		? (long)[(NSHTTPURLResponse *)response statusCode] : 0;
	if (status != 200) {
		NSString *why = sa_error_message(data);
		sa_fail(err, errlen, model, [NSString stringWithFormat:sa_str("HTTP %ld %@"),
			status, why ? why : sa_str("")]);
		// 401/403 is the key itself, 402 an empty balance. 404 is only this model id, so
		// keep going.
		*fatal = (status == 401 || status == 402 || status == 403);
		return NULL;
	}

	id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	id choices = [json isKindOfClass:[NSDictionary class]]
		? [json objectForKey:sa_str("choices")] : nil;
	id first = ([choices isKindOfClass:[NSArray class]] && [choices count] > 0)
		? [choices objectAtIndex:0] : nil;
	id message = [first isKindOfClass:[NSDictionary class]]
		? [first objectForKey:sa_str("message")] : nil;
	id content = [message isKindOfClass:[NSDictionary class]]
		? [message objectForKey:sa_str("content")] : nil;
	if (![choices isKindOfClass:[NSArray class]]) {
		NSString *why = sa_error_message(data);
		sa_fail(err, errlen, model, why ? why : sa_str("unexpected response"));
		return NULL;
	}

	const char *utf8 = [content isKindOfClass:[NSString class]]
		? [(NSString *)content UTF8String] : NULL;
	char *answer = strdup(utf8 ? utf8 : "");
	if (!answer) return NULL;
	sa_strip_reasoning(answer);
	sa_clean(answer);

	if (answer[0] == '\0') {
		free(answer);
		id reason = [first isKindOfClass:[NSDictionary class]]
			? [first objectForKey:sa_str("finish_reason")] : nil;
		// Almost always a reasoning model that spent the length limit before answering.
		sa_fail(err, errlen, model, [reason isEqual:sa_str("length")]
			? sa_str("empty answer, the length limit ran out while the model was thinking")
			: sa_str("empty answer"));
		return NULL;
	}
	return answer;
}

// Tries the chain within the timeout. Returns a malloc'd answer, or NULL with err set.
static char *sa_ask(const char *question, char *err, size_t errlen) {
	if (err && errlen) err[0] = '\0';

	NSString *key = sa_pref_str("apiKey", "");
	if ([key length] == 0) {
		os_log(OS_LOG_DEFAULT, "[SiriAI] no API key set");
		if (err) sa_copy_utf8(err, "no API key set", errlen);
		return NULL;
	}

	NSString *base = sa_base_url();
	BOOL openrouter = sa_is_openrouter(base);
	NSArray *chain = sa_model_chain(openrouter);
	if ([chain count] == 0) {
		os_log(OS_LOG_DEFAULT, "[SiriAI] no model set");
		if (err) sa_copy_utf8(err, "no model set", errlen);
		return NULL;
	}

	// Each model gets an even share of what is left, so the chain fits the window the main
	// thread waits and time freed by a fast failure goes to the models after it. The floor
	// keeps a short timeout from giving a model less time than any of them needs.
	double deadline = CFAbsoluteTimeGetCurrent() + sa_timeout();
	NSUInteger count = [chain count];

	for (NSUInteger i = 0; i < count; i++) {
		double left = deadline - CFAbsoluteTimeGetCurrent();
		if (left < 1.0) break;
		double budget = left / (double)(count - i);
		if (budget < 2.5) budget = left < 2.5 ? left : 2.5;

		BOOL fatal = NO;
		char *answer = sa_ask_model(question, key, base, openrouter,
			[chain objectAtIndex:i], budget, &fatal, err, errlen);
		if (answer) return answer;
		if (fatal) return NULL;
	}
	return NULL;
}

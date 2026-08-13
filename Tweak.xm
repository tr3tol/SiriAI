#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <pthread.h>
#import <sys/time.h>

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define kPrefDomain "com.tr3tol.siriai"

#define kWebSearchPrefix  "WEBINDEX#"
#define kWikiPrefix       "KG#"
#define kCannedChatPrefix "SocialConversation#"

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

static NSString *sa_str(const char *utf8) {
	return [NSString stringWithUTF8String:utf8];
}

static id safe_get(id obj, const char *selName) {
	if (!obj) return nil;
	SEL sel = sel_getUid(selName);
	if (![obj respondsToSelector:sel]) return nil;
	Method m = class_getInstanceMethod(object_getClass(obj), sel);
	if (!m) return nil;
	char *ret = method_copyReturnType(m);
	BOOL isObject = (ret && ret[0] == '@');
	if (ret) free(ret);
	return isObject ? [obj performSelector:sel] : nil;
}

static BOOL safe_set(id obj, const char *selName, id value) {
	if (!obj) return NO;
	SEL sel = sel_getUid(selName);
	if (![obj respondsToSelector:sel]) return NO;
	Method m = class_getInstanceMethod(object_getClass(obj), sel);
	if (!m) return NO;
	if (method_getNumberOfArguments(m) != 3) return NO;
	char *t = method_copyArgumentType(m, 2);
	BOOL isObject = (t && t[0] == '@');
	if (t) free(t);
	if (!isObject) return NO;
	[obj performSelector:sel withObject:value];
	return YES;
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
		if (!plist) continue;
		id value = [plist objectForKey:sa_str(key)];
		if (value) return value;
	}
	return nil;
}

static NSString *sa_pref_str(const char *key, const char *fallback) {
	id v = sa_pref_obj(key);
	if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
	return sa_str(fallback);
}

static BOOL sa_pref_bool(const char *key, BOOL fallback) {
	id v = sa_pref_obj(key);
	if ([v respondsToSelector:sel_getUid("boolValue")]) return [v boolValue];
	return fallback;
}

static double sa_pref_num(const char *key, double fallback) {
	id v = sa_pref_obj(key);
	if ([v respondsToSelector:sel_getUid("doubleValue")]) {
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

// Some models emit their thinking before </think>. Keep only what follows.
static void sa_strip_reasoning(char *s) {
	static const char *marker = "</think>";
	char *end = strstr(s, marker);
	if (!end) return;

	char *answer = end + strlen(marker);
	memmove(s, answer, strlen(answer) + 1);
}

// Drops ASCII markup only. UTF-8 continuation bytes have the high bit set, so Cyrillic
// is untouched.
static void sa_clean(char *s) {
	char *out = s;
	int space = 1;

	for (char *in = s; *in; in++) {
		unsigned char c = (unsigned char)*in;
		if (c == '*' || c == '#' || c == '`' || c == '_') continue;
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

// fatal: a missing or rejected key, which no other model survives either.
static char *sa_ask_model(const char *question, NSString *model, double budget, BOOL *fatal) {
	*fatal = NO;

	NSString *key = sa_pref_str("apiKey", "");
	if ([key length] == 0) {
		*fatal = YES;
		return NULL;
	}

	NSString *base = sa_pref_str("baseURL", kDefaultBaseURL);
	while ([base hasSuffix:sa_str("/")])
		base = [base substringToIndex:[base length] - 1];

	NSURL *url = [NSURL URLWithString:[base stringByAppendingString:sa_str("/chat/completions")]];
	if (!url) return NULL;

	NSMutableDictionary *sys = [NSMutableDictionary dictionary];
	[sys setObject:sa_str("system") forKey:sa_str("role")];
	[sys setObject:sa_prompt_for(question) forKey:sa_str("content")];

	NSMutableDictionary *usr = [NSMutableDictionary dictionary];
	[usr setObject:sa_str("user") forKey:sa_str("role")];
	[usr setObject:sa_str(question) forKey:sa_str("content")];

	NSMutableArray *messages = [NSMutableArray array];
	[messages addObject:sys];
	[messages addObject:usr];

	// Otherwise reasoning ends up in content and gets spoken.
	NSMutableDictionary *reasoning = [NSMutableDictionary dictionary];
	[reasoning setObject:[NSNumber numberWithBool:YES] forKey:sa_str("exclude")];

	NSMutableDictionary *body = [NSMutableDictionary dictionary];
	[body setObject:model forKey:sa_str("model")];
	[body setObject:messages forKey:sa_str("messages")];
	[body setObject:reasoning forKey:sa_str("reasoning")];
	[body setObject:[NSNumber numberWithInt:(int)sa_pref_num("maxTokens", 160)]
		forKey:sa_str("max_tokens")];

	NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
	if (!payload) return NULL;

	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
	[req setHTTPMethod:sa_str("POST")];
	[req setValue:sa_str("application/json") forHTTPHeaderField:sa_str("Content-Type")];
	[req setValue:[sa_str("Bearer ") stringByAppendingString:key]
		forHTTPHeaderField:sa_str("Authorization")];
	[req setHTTPBody:payload];
	[req setTimeoutInterval:budget];

	// Synchronous: no completion block, so no helper process is needed.
	NSURLResponse *response = nil;
	NSData *data = [NSURLConnection sendSynchronousRequest:req
		returningResponse:&response error:nil];
	if (!data) return NULL;

	long status = [response respondsToSelector:sel_getUid("statusCode")]
		? (long)[(NSHTTPURLResponse *)response statusCode] : 0;
	if (status != 200) {
		// 401/403 is the key itself. 404 is only this model id, so keep going.
		*fatal = (status == 401 || status == 403);
		return NULL;
	}

	id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	if (![json isKindOfClass:[NSDictionary class]]) return NULL;

	id choices = [json objectForKey:sa_str("choices")];
	if (![choices isKindOfClass:[NSArray class]] || [choices count] == 0) return NULL;

	id message = [[choices objectAtIndex:0] objectForKey:sa_str("message")];
	if (![message isKindOfClass:[NSDictionary class]]) return NULL;

	id content = [message objectForKey:sa_str("content")];
	if (![content isKindOfClass:[NSString class]] || [(NSString *)content length] == 0) return NULL;

	const char *utf8 = [(NSString *)content UTF8String];
	if (!utf8) return NULL;

	char *answer = strdup(utf8);
	if (answer) {
		sa_strip_reasoning(answer);
		sa_clean(answer);
	}
	return answer;
}

static char *sa_ask(const char *question) {
	NSMutableArray *chain = [NSMutableArray array];
	const char *keys[]     = { "model",        "backupModel",   "lastModel"  };
	const char *fallbacks[] = { kDefaultModel, kDefaultBackup,  kDefaultLast };

	for (int i = 0; i < 3; i++) {
		NSString *model = sa_pref_str(keys[i], fallbacks[i]);
		if ([model length] > 0 && ![chain containsObject:model])
			[chain addObject:model];
	}
	if ([chain count] == 0) return NULL;

	// Split so the chain fits the window the main thread waits. The floor keeps a short
	// timeout from giving each model less time than any of them needs.
	double budget = sa_timeout() / (double)[chain count];
	if (budget < 2.5) budget = 2.5;

	for (NSString *model in chain) {
		BOOL fatal = NO;
		char *answer = sa_ask_model(question, model, budget, &fatal);
		if (answer) return answer;
		if (fatal) return NULL;
	}
	return NULL;
}

#define SA_IDLE    0
#define SA_RUNNING 1
#define SA_DONE    2
#define SA_FAILED  3

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_cond = PTHREAD_COND_INITIALIZER;
static int      g_state = SA_IDLE;
static unsigned g_generation = 0;
static char     g_answer[8192];
static char     g_question[1024];

struct sa_job {
	unsigned generation;
	char question[1024];
};

static void *sa_worker(void *arg) {
	struct sa_job *job = (struct sa_job *)arg;
	@autoreleasepool {
		char *answer = sa_ask(job->question);

		pthread_mutex_lock(&g_lock);
		if (job->generation == g_generation) {
			if (answer) {
				strlcpy(g_answer, answer, sizeof(g_answer));
				g_state = SA_DONE;
			} else {
				g_state = SA_FAILED;
			}
			pthread_cond_broadcast(&g_cond);
		}
		pthread_mutex_unlock(&g_lock);

		free(answer);
	}
	free(job);
	return NULL;
}

static void sa_start(const char *question) {
	struct sa_job *job = (struct sa_job *)calloc(1, sizeof(struct sa_job));
	if (!job) return;

	pthread_mutex_lock(&g_lock);
	job->generation = ++g_generation;
	g_state = SA_RUNNING;
	g_answer[0] = '\0';
	pthread_mutex_unlock(&g_lock);

	strlcpy(job->question, question, sizeof(job->question));

	pthread_t t;
	if (pthread_create(&t, NULL, sa_worker, job) != 0) {
		pthread_mutex_lock(&g_lock);
		g_state = SA_FAILED;
		pthread_cond_broadcast(&g_cond);
		pthread_mutex_unlock(&g_lock);
		free(job);
		return;
	}
	pthread_detach(t);
}

static BOOL sa_collect(char *out, size_t outlen, double seconds) {
	struct timeval now;
	gettimeofday(&now, NULL);

	struct timespec deadline;
	deadline.tv_sec = now.tv_sec + (long)seconds;
	deadline.tv_nsec = now.tv_usec * 1000;

	pthread_mutex_lock(&g_lock);
	while (g_state == SA_RUNNING) {
		if (pthread_cond_timedwait(&g_cond, &g_lock, &deadline) != 0) break;
	}
	BOOL ok = (g_state == SA_DONE && g_answer[0] != '\0');
	if (ok) strlcpy(out, g_answer, outlen);
	pthread_mutex_unlock(&g_lock);
	return ok;
}

static id sa_ace(id item) {
	return safe_get(item, "aceObject");
}

static BOOL sa_has_prefix(id ace, const char *prefix) {
	id ident = safe_get(ace, "dialogIdentifier");
	if (!ident) return NO;
	const char *s = [[ident description] UTF8String];
	if (!s) return NO;
	return strncmp(s, prefix, strlen(prefix)) == 0;
}

static BOOL sa_should_intercept(id ace) {
	if (sa_has_prefix(ace, kWebSearchPrefix)) return YES;
	if (sa_has_prefix(ace, kWikiPrefix)) return sa_pref_bool("interceptWiki", YES);
	if (sa_has_prefix(ace, kCannedChatPrefix)) return sa_pref_bool("interceptChat", NO);
	return NO;
}

static BOOL sa_is_search_card(id ace) {
	if (!ace) return NO;

	id group = safe_get(ace, "groupIdentifier");
	if (group) {
		const char *g = [[group description] UTF8String];
		if (g && strcmp(g, "com.apple.ace.ui.card") == 0) return YES;
	}

	const char *cls = object_getClassName(ace);
	return cls && strstr(cls, "CardSnippet") != NULL;
}

%hook AFConversation

- (void)addItemForSpeechRecognizedCommand:(id)command {
	id question = safe_get(command, "af_bestTextInterpretation");
	const char *utf8 = question ? [[question description] UTF8String] : NULL;
	if (!utf8) {
		%orig;
		return;
	}

	// A new question invalidates the previous answer still sitting in the buffer.
	pthread_mutex_lock(&g_lock);
	strlcpy(g_question, utf8, sizeof(g_question));
	g_generation++;
	g_state = SA_IDLE;
	g_answer[0] = '\0';
	pthread_mutex_unlock(&g_lock);

	if (sa_pref_bool("enabled", YES) && sa_pref_bool("prefetch", NO))
		sa_start(utf8);

	%orig;
}

%end

%hook SiriSharedUICompactViewModelController

- (void)_processInsertedConversationItems:(id)items forConversation:(id)conversation {
	if (![items respondsToSelector:sel_getUid("count")]) {
		%orig;
		return;
	}

	BOOL intercept = NO;
	for (id item in (NSArray *)items) {
		if (sa_should_intercept(sa_ace(item))) { intercept = YES; break; }
	}

	if (!intercept || !sa_pref_bool("enabled", YES)) {
		%orig;
		return;
	}

	// Called repeatedly as items stream in. Only the first call starts a request.
	if (!sa_pref_bool("prefetch", NO)) {
		char question[1024];
		pthread_mutex_lock(&g_lock);
		BOOL start = (g_state == SA_IDLE && g_question[0] != '\0');
		strlcpy(question, g_question, sizeof(question));
		pthread_mutex_unlock(&g_lock);
		if (start) sa_start(question);
	}

	char answer[8192];
	if (!sa_collect(answer, sizeof(answer), sa_timeout() + 1.5)) {
		%orig;
		return;
	}

	BOOL hideCard = sa_pref_bool("hideWebCard", YES);
	NSMutableArray *kept = [NSMutableArray array];
	for (id item in (NSArray *)items) {
		id ace = sa_ace(item);

		if (hideCard && sa_is_search_card(ace)) continue;

		if (sa_should_intercept(ace)) {
			// text is shown, speakableText is spoken. Separate fields.
			id spoken = sa_str(answer);
			safe_set(ace, "setText:", spoken);
			safe_set(ace, "setSpeakableText:", spoken);
			safe_set(ace, "setRedactedSpeakableText:", spoken);
			safe_set(ace, "setRedactedText:", spoken);
			safe_set(ace, "setDialogIdentifier:", sa_str(""));
		}

		[kept addObject:item];
	}

	%orig(kept, conversation);
}

%end

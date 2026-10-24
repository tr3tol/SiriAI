#import <UIKit/UIKit.h>
#import <pthread.h>
#import <sys/time.h>

#import "SiriAICore.h"

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

#define kWebSearchPrefix  "WEBINDEX#"
#define kWikiPrefix       "KG#"
#define kCannedChatPrefix "SocialConversation#"

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

#define SA_IDLE    0
#define SA_RUNNING 1
#define SA_DONE    2
#define SA_FAILED  3

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

// Diagnostics, guarded by g_lock. The tokens stay registered for the life of the process,
// since notifyd drops a name's state once nobody holds it.
static uint64_t g_status;
static int  g_status_token = -1;
static int  g_ident_tokens[kStatusIdents * 2];
static char g_idents[kStatusIdents][17];

static void sa_status_publish_locked(void) {
	if (g_status_token == -1) return;
	uint64_t now = (uint64_t)(uint32_t)time(NULL);
	notify_set_state(g_status_token, (g_status & 0xFFFFFFFFULL) | (now << 32));
}

static void sa_status_locked(uint64_t bits) {
	g_status |= bits;
	sa_status_publish_locked();
}

static void sa_status(uint64_t bits) {
	pthread_mutex_lock(&g_lock);
	sa_status_locked(bits);
	pthread_mutex_unlock(&g_lock);
}

// A new question starts a fresh record; what the process itself is like stays.
static void sa_status_reset_locked(void) {
	g_status &= (SA_ST_LOADED | SA_ST_CONV_CLASS | SA_ST_VIEW_CLASS);
	memset(g_idents, 0, sizeof(g_idents));
	for (int i = 0; i < kStatusIdents * 2; i++)
		if (g_ident_tokens[i] != -1) notify_set_state(g_ident_tokens[i], 0);
	sa_status_publish_locked();
}

// Keeps the first distinct identifiers of the current reply, 16 characters each.
static void sa_note_ident(const char *ident) {
	pthread_mutex_lock(&g_lock);
	for (int i = 0; i < kStatusIdents; i++) {
		if (g_idents[i][0] && strncmp(g_idents[i], ident, 16) == 0) break;
		if (g_idents[i][0]) continue;
		strlcpy(g_idents[i], ident, sizeof(g_idents[i]));
		char padded[17] = {0};
		strncpy(padded, g_idents[i], 16);
		if (g_ident_tokens[2 * i] != -1)
			notify_set_state(g_ident_tokens[2 * i], sa_pack8(padded));
		if (g_ident_tokens[2 * i + 1] != -1)
			notify_set_state(g_ident_tokens[2 * i + 1], sa_pack8(padded + 8));
		break;
	}
	pthread_mutex_unlock(&g_lock);
}
static pthread_cond_t  g_cond = PTHREAD_COND_INITIALIZER;
static int      g_state = SA_IDLE;
static unsigned g_generation = 0;
static char     g_answer[8192];
static char     g_error[512];
static char     g_question[1024];

struct sa_job {
	unsigned generation;
	char question[1024];
};

static void *sa_worker(void *arg) {
	struct sa_job *job = (struct sa_job *)arg;
	@autoreleasepool {
		char err[512];
		char *answer = sa_ask(job->question, err, sizeof(err));

		pthread_mutex_lock(&g_lock);
		if (job->generation == g_generation) {
			if (answer) {
				sa_copy_utf8(g_answer, answer, sizeof(g_answer));
				g_state = SA_DONE;
				sa_status_locked(SA_ST_ANSWERED);
			} else {
				sa_copy_utf8(g_error, err, sizeof(g_error));
				g_state = SA_FAILED;
				sa_status_locked(SA_ST_FAILED);
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
	g_error[0] = '\0';
	sa_status_locked(SA_ST_STARTED);
	pthread_mutex_unlock(&g_lock);

	sa_copy_utf8(job->question, question, sizeof(job->question));

	pthread_t t;
	if (pthread_create(&t, NULL, sa_worker, job) != 0) {
		pthread_mutex_lock(&g_lock);
		g_state = SA_FAILED;
		sa_copy_utf8(g_error, "could not start a thread", sizeof(g_error));
		pthread_cond_broadcast(&g_cond);
		pthread_mutex_unlock(&g_lock);
		free(job);
		return;
	}
	pthread_detach(t);
}

// Waits for the answer. On success out holds it; otherwise out holds the reason, empty when
// nothing was asked.
static BOOL sa_collect(char *out, size_t outlen, double seconds) {
	struct timeval now;
	gettimeofday(&now, NULL);

	long whole = (long)seconds;
	long nsec = now.tv_usec * 1000 + (long)((seconds - (double)whole) * 1e9);

	struct timespec deadline;
	deadline.tv_sec = now.tv_sec + whole + nsec / 1000000000;
	deadline.tv_nsec = nsec % 1000000000;

	int limit = (int)sa_timeout();

	pthread_mutex_lock(&g_lock);
	while (g_state == SA_RUNNING) {
		if (pthread_cond_timedwait(&g_cond, &g_lock, &deadline) != 0) break;
	}
	// Given up on. Later calls for the same reply would otherwise each hold the main thread
	// for the full timeout again, and a late answer would replace one already spoken.
	if (g_state == SA_RUNNING) {
		g_generation++;
		g_state = SA_FAILED;
		snprintf(g_error, sizeof(g_error), "no answer within %d seconds", limit);
		sa_status_locked(SA_ST_TIMEOUT);
	}
	BOOL ok = (g_state == SA_DONE && g_answer[0] != '\0');
	if (ok) sa_copy_utf8(out, g_answer, outlen);
	else sa_copy_utf8(out, g_state == SA_FAILED ? g_error : "", outlen);
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

	sa_prefs_sync();

	// A new question invalidates the previous answer still sitting in the buffer.
	pthread_mutex_lock(&g_lock);
	sa_copy_utf8(g_question, utf8, sizeof(g_question));
	g_generation++;
	g_state = SA_IDLE;
	g_answer[0] = '\0';
	g_error[0] = '\0';
	sa_status_reset_locked();
	sa_status_locked(SA_ST_QUESTION);
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
	sa_status(SA_ST_ITEMS);
	if (!sa_pref_bool("enabled", YES)) {
		sa_status(SA_ST_DISABLED);
		%orig;
		return;
	}

	BOOL intercept = NO;
	for (id item in (NSArray *)items) {
		id ace = sa_ace(item);
		if (!ace) continue;
		sa_status(SA_ST_ACE);

		id ident = safe_get(ace, "dialogIdentifier");
		const char *s = ident ? [[ident description] UTF8String] : NULL;
		if (s && s[0]) {
			sa_status(SA_ST_IDENT);
			sa_note_ident(s);
		}
		os_log(OS_LOG_DEFAULT, "[SiriAI] item %{public}s %{public}s",
			object_getClassName(ace), s ? s : "-");

		if (sa_should_intercept(ace)) intercept = YES;
	}
	if (!intercept) {
		%orig;
		return;
	}
	sa_status(SA_ST_MATCH);

	// Called repeatedly as items stream in. Only the first call starts a request.
	if (!sa_pref_bool("prefetch", NO)) {
		char question[1024];
		pthread_mutex_lock(&g_lock);
		BOOL start = (g_state == SA_IDLE && g_question[0] != '\0');
		sa_copy_utf8(question, g_question, sizeof(question));
		pthread_mutex_unlock(&g_lock);
		if (start) sa_start(question);
	}

	char text[8192];
	if (!sa_collect(text, sizeof(text), sa_timeout() + 1.5)) {
		// Speaking the reason is opt-in; by default Siri's own result stays untouched.
		if (text[0] == '\0' || !sa_pref_bool("debug", NO)) {
			%orig;
			return;
		}
		char spoken[600];
		snprintf(spoken, sizeof(spoken), "SiriAI: %s", text);
		sa_copy_utf8(text, spoken, sizeof(text));
	}

	BOOL hideCard = sa_pref_bool("hideWebCard", YES);
	NSString *spoken = sa_str(text);
	NSMutableArray *kept = [NSMutableArray array];
	for (id item in (NSArray *)items) {
		id ace = sa_ace(item);

		if (hideCard && sa_is_search_card(ace)) continue;

		if (sa_should_intercept(ace)) {
			// text is shown, speakableText is spoken. Separate fields.
			safe_set(ace, "setText:", spoken);
			safe_set(ace, "setSpeakableText:", spoken);
			safe_set(ace, "setRedactedSpeakableText:", spoken);
			safe_set(ace, "setRedactedText:", spoken);
			safe_set(ace, "setDialogIdentifier:", sa_str(""));
		}

		[kept addObject:item];
	}

	sa_status(SA_ST_REPLACED);
	%orig(kept, conversation);
}

%end

%ctor {
	%init;

	pthread_mutex_lock(&g_lock);
	for (int i = 0; i < kStatusIdents * 2; i++) {
		char name[96];
		snprintf(name, sizeof(name), "%s%d", kStatusIdent, i);
		if (notify_register_check(name, &g_ident_tokens[i]) != NOTIFY_STATUS_OK)
			g_ident_tokens[i] = -1;
	}
	if (notify_register_check(kStatusName, &g_status_token) != NOTIFY_STATUS_OK)
		g_status_token = -1;

	static int proc_token = -1;
	if (notify_register_check(kStatusProc, &proc_token) == NOTIFY_STATUS_OK)
		notify_set_state(proc_token, sa_pack8(getprogname()));

	g_status = SA_ST_LOADED;
	if (objc_getClass("AFConversation")) g_status |= SA_ST_CONV_CLASS;
	if (objc_getClass("SiriSharedUICompactViewModelController")) g_status |= SA_ST_VIEW_CLASS;
	sa_status_publish_locked();
	pthread_mutex_unlock(&g_lock);

	os_log(OS_LOG_DEFAULT, "[SiriAI] loaded into %{public}s", getprogname());
}

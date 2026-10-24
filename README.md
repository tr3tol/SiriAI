# SiriAI

A jailbreak tweak for iOS 18 that answers the questions Siri gives up on.

Siri continues to handle everything it already handles — alarms, timers, notes, messages,
device settings. Only the requests it hands off to web search are sent to a language model.
The reply is written back into Siri's own answer object, so it appears in the normal
interface and is spoken in the normal voice.

## How it works

Siri does not refuse a question it cannot answer; it silently falls back to a web search.
That fallback is identified structurally, by the dialog identifier attached to the reply,
rather than by matching any phrase — so the behaviour is the same in every language.

| Reply | Dialog identifier | Intercepted |
| --- | --- | --- |
| Web search fallback | `WEBINDEX#` | always |
| Encyclopedia summary | `KG#` | optional, enabled by default |
| Scripted small talk | `SocialConversation#` | optional, disabled by default |

Anything else is passed through untouched. If no answer arrives within the timeout, Siri's
own result is left exactly as it was.

The request is issued from the injected library itself, on a detached thread, using a
synchronous HTTP call. There is no helper daemon, no launch job and no listening socket;
nothing remains resident once the Siri process exits.

## Installation

Add `https://tr3tol.github.io/repo/` in Sileo, or install the `.deb` directly.

Requires a rootless jailbreak on iOS 18 and `preferenceloader`.

## Configuration

All settings live in **Settings → SiriAI** and take effect immediately.

An API key is the only required field. Any OpenAI-compatible endpoint works, including
OpenRouter, DeepSeek, Groq, Cerebras and locally hosted servers. With any provider other than
OpenRouter, set the model yourself: the defaults are OpenRouter ids and are skipped elsewhere.

For DeepSeek, use base URL `https://api.deepseek.com` and model `deepseek-flash`. Thinking
mode is switched off automatically, since it spends the whole length budget before answering.

**Test connection** sends a short question to every model in the chain and shows each reply,
how long it took, or the provider's exact error. **Speak errors** makes Siri say why a request
failed instead of falling back to its own result. Failures are also logged; filter the device
log for `[SiriAI]`.

| Setting | Purpose |
| --- | --- |
| Model, Backup model, Last resort | Tried in order; a rate-limited model falls through to the next. Clear a backup to skip it |
| Custom prompt | Replaces the built-in prompt entirely |
| Language | Selects the built-in prompt when no custom one is set |
| Length, Timeout | Bound generation time and how long a reply is awaited |
| Article summaries, Scripted replies | Widen what is intercepted |
| Hide search card | Removes the search result beside the answer |
| Ask early | Starts the request when the question is recognised, in parallel with Siri's own round trip, at the cost of one request per command |
| Topic trigger | A comma-separated word list with a prompt of its own |

## Building

Requires [Theos](https://theos.dev) with an iOS SDK. On Linux the arm64e slice is built with
the old ABI, so the code avoids blocks, `@""` literals and compile-time classes; see
`SiriAICore.h`.

```sh
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

## License

GPL-3.0

# SiriAI

Stock Siri keeps working exactly as it does now. Alarms, timers, notes, messages — all
untouched. Only the requests Siri cannot answer itself are sent to a language model, and
the reply is shown on screen and spoken in Siri's own voice.

Built for iOS 18.5, rootless, tested on an iPhone SE (2020).

## What gets replaced

Siri never refuses a question — it quietly falls back to web search. That fallback is the
trigger, so the tweak reacts to what Siri actually did rather than to any phrase:

| Case | Dialog identifier | Replaced |
| --- | --- | --- |
| Web search fallback | `WEBINDEX#` | always |
| Encyclopedia summary | `KG#` | optional, on by default |
| Scripted small talk | `SocialConversation#` | optional, off by default |

Everything else passes through untouched. When no answer arrives in time, Siri's own
result is left in place.

## Setup

Install the deb, then open Settings → SiriAI and enter an API key. Any OpenAI-compatible
endpoint works — the base URL, model and key are all configurable, so OpenRouter, Groq,
Cerebras or a local server are one code path.

## Building

Theos, on device or with a matching toolchain:

```
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

## Notes

Networking lives in the injected dylib itself rather than a helper daemon: nothing runs
in the background, and the request thread dies with the short-lived Siri process. The
request starts as soon as the question is recognised — in parallel with Siri's own round
trip — so the reply is usually ready by the time it is needed.

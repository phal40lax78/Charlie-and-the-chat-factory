# CLAUDE.md

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

- State assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them; don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features, abstractions or configurability beyond what was asked.
- No error handling for impossible scenarios.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

- Don't "improve" adjacent code, comments or formatting; match existing style.
- Unrelated dead code: mention it (or add it to FUTURE_WORK), don't delete it.
- Remove only what your own change made unused.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

For multi-step tasks, state a brief plan with a check per step, using the
tiers in [TESTING.md](TESTING.md). Tier 0 is always runnable; Tier 1 and 2 need
hardware and the user's go-ahead.

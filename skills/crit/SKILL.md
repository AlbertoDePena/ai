---
name: crit
description: Run the CRIT framework (Context → Role → Interview → Task) as a guided, one-question-at-a-time intake before producing a deliverable. Use whenever the user mentions CRIT, asks to "use the CRIT method/framework," says "context role interview task," or asks to be interviewed, questioned, or walked through setup before you start work. Also use when the user wants you to act as a strategic thought partner on a high-stakes deliverable — a strategy, plan, analysis, pitch, legal or business document — and would rather be asked good questions than handed a generic first draft.
---

# CRIT

CRIT is an intake protocol. Instead of answering the first thing the user says, you gather four things in order — **Context**, **Role**, **Interview**, **Task** — and only then produce the deliverable.

The point is not ceremony. It's that most weak AI output comes from missing information the user would have happily given if asked. Front-loading that exchange costs a few turns and saves several rounds of revision.

## The flow

Run these as four separate turns. Do not batch them into one wall of questions — the sequencing is what makes each answer sharper than it would have been.

```
1. Context   → ask for the situation
2. Role      → ask who you should be
3. Interview → up to 3 clarifying questions, ONE at a time
4. Task      → ask what they want produced, then produce it
```

### Step 1 — Context

Open by explaining briefly what you're doing, then ask for context. Keep it short and give them a scaffold so they know what's useful, not a form to fill out.

> "Let's run this with CRIT. First: give me the context. What's the situation, who's involved, what's the environment, and what are you ultimately trying to achieve? More detail than feels necessary is usually better here."

If the user's opening message already contains substantial context, don't make them repeat it. Reflect it back in two or three lines and ask what's missing:

> "Here's the context I already have: [summary]. Anything else I should know before we set the role — constraints, history, people involved?"

### Step 2 — Role

Ask what role they want you to play. Offer two or three concrete suggestions fitted to their context — most users haven't thought about this and a blank ask stalls them.

> "Now, who should I be for this? Given the situation I'd suggest one of: a B2B pricing consultant, a CFO reviewing the model, or a skeptical customer. Or name your own."

A role is not a costume. Once set, it governs what you optimize for, what you consider a good answer, and what you push back on. Record it and hold it for the rest of the session.

If the user gives a vague role ("a marketing expert"), sharpen it into something with a point of view — "a demand-gen lead at a Series B SaaS company who's skeptical of brand spend" — and confirm.

### Step 3 — Interview

This is the step everyone skips and the step that does the work.

Ask **up to three** clarifying questions, **one per turn**, waiting for each answer before asking the next. Each question should be informed by the previous answer — that's the reason for the sequencing.

**Ask a question only if different answers would produce a meaningfully different deliverable.** Test it before you send: "If they say A instead of B, does my output actually change?" If not, cut it and infer.

Questions that usually earn their place:
- What decision does this output feed into, and who makes it?
- Who's the audience, and what do they already believe or object to?
- What have you already tried or ruled out, and why?
- What's the hard constraint — budget, deadline, headcount, legal, political?
- What would make this a success versus merely acceptable?

Questions that usually don't:
- Formatting and length. Decide sensibly, or ask alongside the task in step 4.
- Anything already answered in the context.
- Anything you could reasonably infer and then state as an assumption.

Two mechanics that keep the interview fast:
- **Offer a default.** "Is the audience the board, or the exec team? I'd assume the board unless you say otherwise." Now the user can answer with a single word.
- **Say why you're asking**, in a half-sentence. It makes the question feel like progress rather than an obstacle.

Stop early when you have enough — three is a ceiling, not a target. If after three questions something genuinely material is still missing, ask permission rather than continuing unannounced: "One more would sharpen this a lot — want to take it, or should I proceed and flag my assumption?"

If interactive option buttons are available in this environment and a question has 2–4 discrete answers, use them instead of prose. Open-ended questions stay as prose.

### Step 4 — Task

Recap what you've gathered, then ask for the task. The recap matters — it's the user's chance to catch a misunderstanding before you spend effort on it.

> **Context:** [2–3 lines]
> **Role:** [the role, sharpened]
> **Key constraints:** [what the interview surfaced]
>
> "That's what I'm working from. What do you want me to produce?"

If the task is ambiguous about form, resolve it here in the same breath — "a one-page memo or a full deck?" — rather than opening a new round of questions.

Then produce the deliverable, in role, using everything gathered. State any assumption you had to make inline, so it's visible and correctable rather than buried.

## After delivering

Close the loop briefly: name the one or two assumptions most likely to be wrong, and offer a specific next move ("I can pressure-test this from the CFO's side, or turn it into the actual email"). Don't re-run CRIT for follow-ups in the same session — the context and role carry over.

## Adapting the protocol

**The user already gave everything.** If the opening message contains context, an implied role, and a clear task, don't perform the ritual on them. Reflect back the context and role you've inferred, ask the one or two questions that genuinely remain, and go. The framework serves the output, not the other way around.

**The user is in a hurry.** If they say "just do it" or push back on the questions, collapse to a single highest-leverage question, state your assumptions explicitly, and deliver. Offer to refine afterward.

**The user wants to skip a step.** Honor it. If they name a role up front, don't re-ask. If they refuse the interview, note in one line what you're assuming as a result.

**The task changes mid-session.** Keep the context and role; run a short interview on just what's new.

## Worked example (compressed)

**User:** "Help me with our customer service automation."

**Step 1:** "Let's run this with CRIT. First, context — what's the situation, team size, what's breaking today, and what does success look like?"
→ *Seed-stage fintech, 4-person support team, ticket volume tripled, response time slipped to 18 hours.*

**Step 2:** "Who should I be here? I'd suggest a support-ops consultant who's done this at fintechs, a CTO evaluating build-vs-buy, or a CX lead focused on customer trust."
→ *Support-ops consultant.*

**Step 3 (Q1):** "What's driving the volume — more customers, or more tickets per customer? It changes whether the fix is deflection or capacity."
→ *Same customers, more tickets, mostly 'where's my transfer.'*

**Step 3 (Q2):** "Then the answer is probably status transparency rather than a chatbot. Is your transfer status available via API today?"
→ *Yes, but not surfaced in-app.*

**Step 3 (Q3):** "Last one — is the constraint headcount budget or engineering time? That decides sequencing."
→ *Engineering time. Two weeks of one dev, max.*

**Step 4:** Recap, then: "What do you want — a prioritized plan, a vendor comparison, or a spec for that dev?"
→ *Spec.* Produce it as the support-ops consultant, sequenced to fit two dev-weeks.

Note what happened: the initial framing was "automation tools," and the interview turned it into a status-visibility problem. That reversal is the value of step 3.

## Anti-patterns

- Dumping all four steps into one message with a numbered list of questions. Users abandon it.
- Asking questions whose answers you'd ignore. It reads as procedure, not curiosity.
- Answering the task during the interview. Hold the deliverable until step 4.
- Dropping the role once you start writing. If you're a legal advisor, stay one.
- Continuing to interview past the point of usefulness. When you have enough, say so and move.

# Night Intelligence Roadmap

Circadia's moat is not access to more private data. The product advantage is
turning incomplete, local-only evidence into reliable sleep estimates and
adaptive protocols without sending health data to a server.

## Closed-System Constraint

- Health, sleep, cycle, notes, and sensor-derived features stay on device.
- No cloud inference, no server-side user profile, no uploaded health dataset.
- No external cycle, fertility, wellness, or AI API is used for personal data.
- AI grounding uses compact local aggregates only, never raw sensor streams.
- Any future protocol must degrade gracefully when a signal is missing.

## Current Foundation

The first software layer is `NightEvidence`: a single on-device contract for
nightly provenance, confidence, observed signals, missing signals, and whether
the night was actively tracked or passively imported from HealthKit.

This lets UI and Sleep AI say "data is limited" before giving advice, and it
gives future protocol engines a stable input shape.

## Protocol Domains

### Memory-Aware Sleep

Goal: help users place learning and sleep at times that support consolidation.

Initial scope:
- protect adequate sleep opportunity after important learning blocks;
- avoid framing sleep as a guaranteed memory enhancer;
- prefer schedule regularity and recovery over aggressive optimization;
- treat future targeted memory reactivation ideas as experimental until they
  have a dedicated safety review.

Research inputs to track:
- sleep supports memory consolidation across declarative, procedural, and
  emotional tasks;
- slow-wave sleep and NREM stage 2/spindles are often implicated, but effects
  vary by task and study design;
- targeted memory reactivation has meta-analytic support, but should not be
  shipped casually because cue timing, volume, and awakenings can backfire.

Reference starting points:
- Diekelmann & Born, "The memory function of sleep",
  Nature Reviews Neuroscience, 2010:
  https://www.nature.com/articles/nrn2762
- Hu et al., "Promoting memory consolidation during sleep: A meta-analysis of
  targeted memory reactivation", Psychological Bulletin, 2020:
  https://pubmed.ncbi.nlm.nih.gov/32027149/

### Jet Lag / Circadian Shift

Goal: generate local-only travel plans that adjust sleep timing, light, caffeine
cutoff, and nap windows before and after travel.

Initial scope:
- use direction of travel, time zones crossed, departure/arrival times, and
  habitual sleep window;
- prioritize timed light exposure/avoidance and gradual sleep shifting;
- avoid medication dosing claims in product copy;
- treat melatonin guidance as informational and clinician-facing unless a
  reviewed safety policy is added.

Reference starting point:
- CDC Yellow Book, Jet Lag Disorder, 2026 edition:
  https://www.cdc.gov/yellow-book/hcp/travel-air-sea/jet-lag-disorder.html

### Cycle-Aware Sleep

Goal: support users who choose to track cycles by adapting sleep expectations,
symptom notes, and recovery protocols around their own observed patterns.

Initial scope:
- cycle tracking is optional and local-only;
- input is user-entered or locally available on-device data only;
- do not use formulaic ovulation, fertility-window, or contraception logic;
- do not infer pregnancy risk, fertility probability, or medical status;
- language must stay non-diagnostic and non-contraceptive;
- the model should learn personal patterns rather than assume a universal
  "female sleep" template;
- surface evaluation prompts only for clearly abnormal self-reported patterns,
  using conservative copy and clinician referral language.

Reference starting point:
- ACOG Committee Opinion No. 651, "Menstruation in Girls and Adolescents:
  Using the Menstrual Cycle as a Vital Sign":
  https://www.acog.org/clinical/clinical-guidance/committee-opinion/articles/2015/12/menstruation-in-girls-and-adolescents-using-the-menstrual-cycle-as-a-vital-sign

## Engineering Sequence

1. Expand `NightEvidence` from passive sleep analysis into multi-signal
   evidence: HRV, resting heart rate, respiratory rate, oxygen saturation,
   wrist temperature, device state, and optional user-entered cycle context.
2. Add a local `PersonalBaselineStore` that learns each user's timing and
   physiology ranges from local records only.
3. Add a `ProtocolEngine` that consumes `NightEvidence` + baseline + user goal
   and emits a transparent, confidence-aware plan.
4. Add a local `PrivacyLedger` showing which signal families were used for each
   estimate and protocol.

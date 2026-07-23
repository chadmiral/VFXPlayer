# Animatable Attributes

VFXPlayer drives `ParticleEmitter`, `PointLight`, and `SpotLight` instances inside a model tagged **`VFXSequence`**. Set attributes on those instances to control timing and animation curves.

Each instance animates through up to three **stages** that play back-to-back: **`Stand`**, **`Hold`**, then **`Decay`**. Every stage has its own timing (delay + duration) and its own set of animation curves. Curve attributes are named `<Stage><Property>` — for example `StandSizeScaleOverDuration`, `HoldBrightnessScaleOverDuration`, or `DecayTransparencyScaleOverDuration`.

Curve attributes use normalized time **0 → 1** over that stage's `Duration`. At `t = 0` the curve's first keypoint is used; at `t = 1` the last keypoint is used.

Unless noted, scale curves **multiply** the instance's property value captured when the sequence starts. Tint curves **multiply** color channels (RGB) against the base color.

---

## Stages

The three stages always play in the order **`Stand` → `Hold` → `Decay`**, one after another along a single timeline that starts when the sequence begins.

| Stage | Repeats | Purpose (by convention) |
|-------|---------|-------------------------|
| `Stand` | Once | Ramp-up / establishing state of the effect. |
| `Hold` | `HoldLoopCount` times | Sustained, optionally looping, body of the effect. |
| `Decay` | Once | Fade-out / dissipation of the effect. |

### Timing model

Each stage is placed on the timeline sequentially:

1. A stage's `<Stage>Delay` inserts a gap **before** that stage begins, measured from the end of the previous stage (or from the sequence start, for the first active stage).
2. The stage then runs for `<Stage>Duration` seconds. `Hold` runs its duration `HoldLoopCount` times (its curves restart from `t = 0` on each iteration).
3. The next stage begins immediately after (plus its own delay).

A stage with a `Duration` of `0` (or unset, except `Stand` — see below) is **skipped entirely**, and its delay is ignored.

### Holding behavior between and around stages

- **Before the first stage** (during its delay): the instance is held at its starting/off state — emission is suppressed (`Rate = 0` for emitters, `Brightness = 0` for lights) and other properties are held at their base values.
- **In a gap between two stages** (caused by a delay): the previous stage is frozen at its final value (`t = 1`).
- **After the final stage ends**: the last stage is frozen at its final value (`t = 1`) until the sequence ends or loops.

For `ParticleEmitter` instances, whenever a stage has elapsed (both of the frozen cases above), the emitter's `Rate` is additionally forced to `0`. This stops new particles from spawning while every other property stays frozen, so particles that already exist finish out their normal lifetime instead of being killed. Lights remain fully frozen (including `Brightness`) in these states.

### Stage timing attributes

Set these on each `ParticleEmitter` / light. Every attribute is optional.

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `StandDelay` | `number` | `0` | Gap before the stand stage begins. |
| `StandDuration` | `number` | parent sequence `Duration` | Length of the stand stage. Defaults to the whole sequence, so a single-stage effect only needs to set stand curves. Set to `0` to disable the stand stage. |
| `HoldDelay` | `number` | `0` | Gap after stand ends, before hold begins. |
| `HoldDuration` | `number` | `0` (skipped) | Length of **one** hold iteration. |
| `HoldLoopCount` | `number` | `1` | Number of times the hold stage repeats. |
| `DecayDelay` | `number` | `0` | Gap after hold ends, before decay begins. |
| `DecayDuration` | `number` | `0` (skipped) | Length of the decay stage. |

---

## VFXSequence (root model)

Tag the root model with **`VFXSequence`** (via CollectionService) and set these attributes on that model.

| Attribute | Type | Description |
|-----------|------|-------------|
| `Duration` | `number` | Total sequence length in seconds. Required for playback; when elapsed time exceeds this value, the sequence stops or loops. Also used as the default `StandDuration` for child emitters and lights that do not define their own. |
| `Looping` | `boolean` | If `true`, the sequence restarts from the beginning when `Duration` elapses. If unset or `false`, the sequence is removed after one play-through. |
| `PlayOnStart` | `boolean` | If `true`, the sequence begins playing automatically when the client initializes. Sequences without this attribute (or with it set to `false`) must be started by other game logic. |

### Notes

- The root model's `Duration` governs when the whole sequence ends or loops, independent of the per-instance stage timeline. If the stages of an instance total more than the sequence `Duration`, later stages may be cut off; if they total less, the final stage is frozen until the sequence ends.
- On loop, all particle and light drivers are re-initialized and per-cycle state (such as burst emission) is reset.

---

## ParticleEmitter

Apply these attributes to any `ParticleEmitter` descendant of a `VFXSequence` model. Curve attributes exist per stage — prefix each with `Stand`, `Hold`, or `Decay`.

| Curve (per stage) | Type | Affects | Description |
|-------------------|------|---------|-------------|
| `<Stage>EmissionScaleOverDuration` | `NumberSequence` | `Rate` | Scales the emitter's base `Rate` over the stage. |
| `<Stage>BrightnessScaleOverDuration` | `NumberSequence` | `Brightness` | Scales the emitter's base `Brightness` over the stage. |
| `<Stage>LightEmissionScaleOverDuration` | `NumberSequence` | `LightEmission` | Scales the emitter's base `LightEmission` over the stage. |
| `<Stage>LightInfluenceScaleOverDuration` | `NumberSequence` | `LightInfluence` | Scales the emitter's base `LightInfluence` over the stage. |
| `<Stage>SizeScaleOverDuration` | `NumberSequence` | `Size` | Scales every keypoint in the emitter's base `Size` `NumberSequence` over the stage. |
| `<Stage>TransparencyScaleOverDuration` | `NumberSequence` | `Transparency` | Scales every keypoint in the emitter's base `Transparency` `NumberSequence` over the stage. |
| `<Stage>TintOverDuration` | `ColorSequence` | `Color` | Multiplies each keypoint in the emitter's base `Color` `ColorSequence` by the evaluated tint color over the stage. |

Non-curve attributes (also per stage):

| Attribute (per stage) | Type | Affects | Description |
|-----------------------|------|---------|-------------|
| `<Stage>BurstCount` | `number` | Emission | If set, emits this many particles once when that stage begins. Fires only once per stage — the looping `Hold` stage does **not** re-fire its burst on subsequent loop iterations. |

Distance fade attribute (whole emitter, not per stage):

| Attribute | Type | Affects | Description |
|-----------|------|---------|-------------|
| `FadeDistance` | `NumberRange` | `Transparency` / `Enabled` | Camera-distance fade range in studs. `Min` is where the emitter begins to fade out (fully visible nearer than this); `Max` is where the fade is complete (fully transparent). At or beyond `Max` the emitter is disabled to stop emitting; it is automatically re-enabled once the camera moves back within `Max`. |

Base value overrides (whole emitter, not per stage):

Scale and tint curves multiply against a **base value** for each property. By default the base value is the emitter's native property, but you can override it with a `Base<Property>` attribute of the matching type. When present, the attribute is used as the base that the curves scale/tint against; when absent, the native property is used.

| Attribute | Type | Overrides base of |
|-----------|------|-------------------|
| `BaseRate` | `number` | `Rate` |
| `BaseBrightness` | `number` | `Brightness` |
| `BaseLightEmission` | `number` | `LightEmission` |
| `BaseLightInfluence` | `number` | `LightInfluence` |
| `BaseSize` | `NumberSequence` | `Size` |
| `BaseTransparency` | `NumberSequence` | `Transparency` |
| `BaseColor` | `ColorSequence` | `Color` |

For example, `BaseRate` is the emission rate that `StandEmissionScaleOverDuration` (and the other stages' emission curves) multiply against, regardless of the emitter's authored `Rate`.

Additionally:

| Attribute | Type | Affects | Description |
|-----------|------|---------|-------------|
| `BaseSizeMultiplier` | `number` | `Size` | Scalar applied to the resolved base size (`BaseSize` if set, otherwise the native `Size`) when the sequence starts. Every keypoint of the base size `NumberSequence` is multiplied by this value, so it composes multiplicatively with the per-stage `<Stage>SizeScaleOverDuration` curves. Defaults to `1` (no change) when unset. |

Example attributes for a two-stage emitter: `StandEmissionScaleOverDuration`, `StandSizeScaleOverDuration`, `StandBurstCount`, `DecayTransparencyScaleOverDuration`, plus timing `StandDuration = 0.5`, `DecayDuration = 1.0`.

### Notes

- Base values (`Rate`, `Brightness`, `LightEmission`, `LightInfluence`, `Size`, `Color`, `Transparency`, `Enabled`) are read from the instance when the sequence starts or loops. For every property except `Enabled`, a `Base<Property>` attribute (see above) takes precedence over the native value when present.
- Once a stage has elapsed (in a gap before the next stage, or after the final stage), `Rate` is forced to `0` while all other properties stay frozen at the ended stage's final values — already-spawned particles continue their lifetime, but no new particles are emitted.
- **Distance fade:** `FadeDistance` must be set for the fade to activate. Each frame, the camera-to-emitter distance (measured to the emitter's parent `BasePart` or `Attachment`) produces a fade factor that is layered on top of the stage `Transparency` — at `FadeDistance.Min` the emitter is fully visible, at `FadeDistance.Max` it is fully transparent, interpolating linearly in between. This fade multiplies opacity, so it composes with any `<Stage>TransparencyScaleOverDuration` animation. Beyond `FadeDistance.Max` the emitter's `Enabled` is set to `false` (stopping new emission while existing particles finish their lifetime); it is restored to its authored `Enabled` value once the camera is within `FadeDistance.Max`. If the attribute is unset, no distance fade or culling is applied.
- Within an active stage, any property whose curve is **not** set for that stage is driven back to its base value. This means a property animated in `Stand` returns to its base during `Hold`/`Decay` unless those stages also define a curve for it.
- Omitting all curve attributes for a stage leaves every property at its base value for that stage's window.

---

## Lights (`PointLight`, `SpotLight`)

Apply these attributes to any `PointLight` or `SpotLight` descendant of a `VFXSequence` model. Curve attributes exist per stage — prefix each with `Stand`, `Hold`, or `Decay`.

| Curve (per stage) | Type | Affects | Description |
|-------------------|------|---------|-------------|
| `<Stage>BrightnessScaleOverDuration` | `NumberSequence` | `Brightness` | Scales the light's base `Brightness` over the stage. |
| `<Stage>RangeScaleOverDuration` | `NumberSequence` | `Range` | Scales the light's base `Range` over the stage. |
| `<Stage>AngleScaleOverDuration` | `NumberSequence` | `Angle` | **SpotLight only.** Scales the light's base `Angle` over the stage. Ignored on `PointLight`. |
| `<Stage>TintOverDuration` | `ColorSequence` | `Color` | Multiplies the light's base `Color` by the evaluated tint color over the stage. |

### Notes

- Base values (`Brightness`, `Range`, `Angle`, `Color`) are read from the instance when the sequence starts or loops.
- Within an active stage, any property whose curve is **not** set for that stage is driven back to its base value.
- Omitting all curve attributes for a stage leaves every property at its base value for that stage's window.

# Animatable Attributes

VFXPlayer drives `ParticleEmitter`, `PointLight`, and `SpotLight` instances inside a model tagged **`VFXSequence`**. Set attributes on those instances to control timing and animation curves.

Curve attributes use normalized time **0 → 1** over each instance's effective duration (after its delay). At `t = 0` the curve's first keypoint is used; at `t = 1` the last keypoint is used.

Unless noted, scale curves **multiply** the instance's property value captured when the sequence starts. Tint curves **multiply** color channels (RGB) against the base color.

---

## VFXSequence (root model)

Tag the root model with **`VFXSequence`** (via CollectionService) and set these attributes on that model.

| Attribute | Type | Description |
|-----------|------|-------------|
| `Duration` | `number` | Total sequence length in seconds. Required for playback; when elapsed time exceeds this value, the sequence stops or loops. Also used as the default `Duration` for child emitters and lights that do not define their own. |
| `Looping` | `boolean` | If `true`, the sequence restarts from the beginning when `Duration` elapses. If unset or `false`, the sequence is removed after one play-through. |
| `PlayOnStart` | `boolean` | If `true`, the sequence begins playing automatically when the client initializes. Sequences without this attribute (or with it set to `false`) must be started by other game logic. |

### Notes

- The root model's `Duration` governs when the sequence ends or loops; individual emitters and lights can override this with their own `Duration` attribute for per-instance animation windows.
- On loop, all particle and light drivers are re-initialized and per-cycle state (such as burst emission) is reset.

---

## ParticleEmitter

Apply these attributes to any `ParticleEmitter` descendant of a `VFXSequence` model.

| Attribute | Type | Affects | Description |
|-----------|------|---------|-------------|
| `Duration` | `number` | Timing | Length of the animation window in seconds. Falls back to the parent sequence's `Duration` if unset. |
| `Delay` | `number` | Timing | Seconds to wait before animation begins. Default: `0`. During delay, emission is suppressed (`Rate = 0`) and properties are held at their starting values. |
| `BurstCount` | `number` | Emission | If set, emits this many particles once when the delay ends (once per sequence cycle). |
| `EmissionScaleOverDuration` | `NumberSequence` | `Rate` | Scales the emitter's base `Rate` over the duration. |
| `BrightnessScaleOverDuration` | `NumberSequence` | `Brightness` | Scales the emitter's base `Brightness` over the duration. |
| `LightEmissionScaleOverDuration` | `NumberSequence` | `LightEmission` | Scales the emitter's base `LightEmission` over the duration. |
| `LightInfluenceScaleOverDuration` | `NumberSequence` | `LightInfluence` | Scales the emitter's base `LightInfluence` over the duration. |
| `SizeScaleOverDuration` | `NumberSequence` | `Size` | Scales every keypoint in the emitter's base `Size` `NumberSequence` over the duration. |
| `TransparencyScaleOverDuration` | `NumberSequence` | `Transparency` | Scales every keypoint in the emitter's base `Transparency` `NumberSequence` over the duration. |
| `TintOverDuration` | `ColorSequence` | `Color` | Multiplies each keypoint in the emitter's base `Color` `ColorSequence` by the evaluated tint color over the duration. |

### Notes

- Base values (`Rate`, `Brightness`, `LightEmission`, `LightInfluence`, `Size`, `Color`, `Transparency`) are read from the instance when the sequence starts or loops.
- If `Duration` is unset or `<= 0`, curve attributes have no effect after the delay (aside from a one-shot `BurstCount` emit).
- Omitting a curve attribute leaves that property at its base value for the full animation window.

---

## Lights (`PointLight`, `SpotLight`)

Apply these attributes to any `PointLight` or `SpotLight` descendant of a `VFXSequence` model.

| Attribute | Type | Affects | Description |
|-----------|------|---------|-------------|
| `Duration` | `number` | Timing | Length of the animation window in seconds. Falls back to the parent sequence's `Duration` if unset. |
| `Delay` | `number` | Timing | Seconds to wait before animation begins. Default: `0`. During delay, the light is off (`Brightness = 0`) and other properties are held at their starting values. |
| `BrightnessScaleOverDuration` | `NumberSequence` | `Brightness` | Scales the light's base `Brightness` over the duration. |
| `RangeScaleOverDuration` | `NumberSequence` | `Range` | Scales the light's base `Range` over the duration. |
| `AngleScaleOverDuration` | `NumberSequence` | `Angle` | **SpotLight only.** Scales the light's base `Angle` over the duration. Ignored on `PointLight`. |
| `TintOverDuration` | `ColorSequence` | `Color` | Multiplies the light's base `Color` by the evaluated tint color over the duration. |

### Notes

- Base values (`Brightness`, `Range`, `Angle`, `Color`) are read from the instance when the sequence starts or loops.
- If `Duration` is unset or `<= 0`, curve attributes have no effect after the delay.
- Omitting a curve attribute leaves that property at its base value for the full animation window.

# stdlib/anim → `q64.anim`

Animation primitives: transforms, keyframes, curves, skeletons, skinning,
inverse kinematics.

> **Status: not yet implemented.**

## Surface (planned)

- **`Transform`** — rigid (rotation + translation). **`AffineTransform`** —
  adds non-uniform scale. Kept separate so rigid-bone code doesn't branch on
  whether scale is present.
- **`Keyframe.<T>`** — time + value.
- **`Curve.<T>`** — ordered keyframes + interpolation policy. The interpolation
  algorithm comes from `T`'s algebra (slerp for `Quat`, lerp for `Vec3`, etc).
- **`Skeleton`** — rooted hierarchy of `Bone`.
- **`AnimClip`** — named tracks of `Curve.<Transform>`.
- **`pose_skeleton(skel, clip, t)`** — produces the skinning matrix array.
- **IK solvers** — two-bone, FABRIK.

Built on top of [`q64.math`](../math). Integrates with the stream runtime:
an animation is a graph stage consuming a clock signal and producing
transform streams.

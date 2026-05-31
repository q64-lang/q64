# stdlib/ai → `q64.ai`

Token, vocabulary, and model primitives for language and multimodal AI
workloads.

> **Status: not yet implemented.**

## Surface (planned)

- **`Vocab`** — zero-sized marker kind identifying a tokenizer.
- **`Token<V: Vocab, Repr>`** — a token's vocabulary identity + storage width.
  Tokens are not interchangeable across vocabularies; vocab-to-vocab crossing
  is an explicit named operation (`translate(V1, V2)`).
- **`Model<InVocab, OutVocab>`** — a model parameterized by input and output
  vocabularies in the type. A pipeline mismatch (feeding GPT4 tokens into a
  Llama decoder) fails at compile time, not 30 seconds into inference.
- **Sampling**: `sample(logits, cfg)` with temperature / top-k / top-p / seed.
- **Decoding**: token streams → text streams, with optional per-token
  logprobs for speculative decoding and constrained generation.

Inference itself runs through the runtime adapter (host BLAS / WebGPU /
WebNN); this qube provides the type-safe surface.

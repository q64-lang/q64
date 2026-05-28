// "Dilbert lines" (internal name) — rotating teaser shown on Continuum's
// landing page. Picked uniformly at random on every request. Add lines
// freely; the picker scales to any length.

export const DILBERT_LINES: readonly string[] = [
  "Compile beyond the known runtime.",
  "Build where the boundary used to be.",
  "From prompt to process. From process to world.",
  "Ship systems from imagination.",
  "The future should be executable.",
  "Turn intent into infrastructure.",
  "Where agents become services.",
  "Speak the system into existence.",
  "Deploy the impossible, one artifact at a time.",
  "Code for realities not yet named.",
  "A language for builders beyond the edge.",
  "Create artifacts that move, think, and run.",
  "From voice to world in one continuous build.",
  "Build machines out of meaning.",
  "Runtime for the next continuum.",
  "When the prompt becomes the product.",
  "Compose worlds. Deploy them.",
  "Where low-level power meets cosmic intent.",
  "The shortest path from idea to running system.",
  "Make reality programmable.",
  "A build system for imagined machines.",
  "Tools for the post-desktop creator.",
  "Your agents need somewhere to live.",
  "Host the things that think, render, and respond.",
  "Beyond scripts. Into systems.",
  "It isn't safe at the edge. That's why it matters.",
  "The build never ends.",
  "The boundary never holds.",
  "The runtime never rests.",
  "The experiment never ends.",
  "The continuum keeps compiling.",
];

export function pickDilbertLine(): string {
  return DILBERT_LINES[Math.floor(Math.random() * DILBERT_LINES.length)];
}

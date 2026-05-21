# runtime/audio-host

The audio plugin runtime adapter. Targets VST3, AU, and AAX hosts (DAWs).

> **Status: not yet implemented.**

## Responsibilities

- **Real-time scheduling**: pin `@realtime` stages to the host's audio
  callback thread; never block, never allocate.
- **Parameter automation**: lock-free FIFOs for moving parameter changes
  from the host's UI thread to the audio thread without locks.
- **Plugin wrappers**: VST3 / AU / AAX wrapper code that exposes the q64
  graph as an audio plugin to the host DAW.
- **MIDI**: `Event.<MidiMessage>` plumbed from the host's MIDI input.
- **Preset/state**: persistence using the host's preset mechanisms.

## Implementation language

Zig (with the small amount of C/C++ glue each plugin SDK requires).

## Plugin SDKs

VST3, AU, and AAX SDKs are vendored separately (and have their own licenses).
The audio-host adapter is the bridge; the SDK headers are not redistributed
from this repo.

// TEST: golden — stream graph with stages and the pipe operator
// SPEC: streams.md#graph-declaration
// EXPECTED: ok

@stage
fn mic_input -> Signal<PCM<f32>, 48.kHz> {
    env.audio.input()
}

@stage @fuse
fn denoise<const R: Hz>(input: Signal<PCM<f32>, R>, threshold: f32)
    -> Signal<PCM<f32>, R>
{
    input.map(|x| if x.abs() < threshold { PCM<f32>(0.0) } else { x })
}

@stage
fn play(pcm: Signal<PCM<f32>, 48.kHz>) @realtime {
    env.audio.write(pcm)
}

graph audio_path {
    let pcm   = mic_input()
    let clean = pcm |> denoise(threshold: 0.05)
    let _     = clean |> play
}

fn main {
    scope {
        let h = audio_path.start()
        sleep(60.s)
        h.cancel()
    }
}

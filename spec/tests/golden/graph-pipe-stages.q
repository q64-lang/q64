// TEST: golden — stream graph with stages and the pipe operator
// SPEC: streams.md#graph-declaration
// EXPECTED: ok

@stage
fn mic_input(a: Audio) -> Signal<PCM<f32>, 48.kHz> {
    a.input()
}

@stage @fuse
fn denoise<const R: Hz>(input: Signal<PCM<f32>, R>, threshold: f32)
    -> Signal<PCM<f32>, R>
{
    input.map(|x| if x.abs() < threshold { PCM<f32>(0.0) } else { x })
}

@stage
fn play(a: Audio, pcm: Signal<PCM<f32>, 48.kHz>) @realtime {
    a.write(pcm)
}

graph audio_path(env: Env) {
    let pcm   = mic_input(env.audio)
    let clean = pcm |> denoise(threshold: 0.05)
    let _     = clean |> play(env.audio)
}

fn main(env: Env) {
    scope {
        let h = audio_path.start(env)
        sleep(60.s)
        h.cancel()
    }
}

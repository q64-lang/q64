// TEST: STR060 — @realtime × |> effect violation
// SPEC: streams.md#effects-on-stages
// EXPECTED: error
//
// `@realtime` stage piped into a non-`@realtime` stage.

@stage
fn play(a: Audio, pcm: Signal<PCM<f32>, 48.kHz>) @realtime {
    a.write(pcm)
}

@stage
fn http_post(n: Net, url: Url, body: Signal<Bytes, 60.Hz>) {
    n.post(url, body.current())
}

fn main {
    scope {
        let g = graph audio_path {
            let _ = mic_input(env.audio)
                |> play(env.audio)
                |> http_post(env.net, url"https://example.com")
        }
        let _ = g.start()
    }
}

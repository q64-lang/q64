// TEST: golden — Result, try, From-based conversion
// SPEC: errors.md#multi-error-functions
// EXPECTED: ok

pub enum ConfigError {
    Io(IoError),
    Parse(JsonError),
}

pub fit ConfigError : From<IoError>   { fn from(e: IoError)   -> Self { Io(e)    } }
pub fit ConfigError : From<JsonError> { fn from(e: JsonError) -> Self { Parse(e) } }

pub fit ConfigError : Display {
    fn fmt(self) -> str {
        match self {
            Io(_)    -> "couldn't read config from disk",
            Parse(_) -> "config file is malformed",
        }
    }
}

pub fit ConfigError : Error { }

pub struct Config { name: str }

pub fn load_config(path: str) -> Result<Config, ConfigError> {
    let bytes        = try env.fs.read(path)
    let cfg: Config  = try bytes.json()
    Ok(cfg)
}

fn main -> Result<(), Error> {
    let cfg = try load_config("config.json")
    env.out("loaded: {cfg.name}")
    Ok(())
}

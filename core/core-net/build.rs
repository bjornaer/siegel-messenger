// Generates Rust types from /proto (SRV-02) with a pure-Rust compiler: no protoc needed.
fn main() {
    let fds =
        protox::compile(["siegel/v1/identity.proto"], ["../../proto"]).expect("compile proto");
    prost_build::Config::new()
        .compile_fds(fds)
        .expect("generate rust");
    println!("cargo:rerun-if-changed=../../proto");
}

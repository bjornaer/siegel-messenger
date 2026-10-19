// Generates Rust types from /proto (SRV-02) with a pure-Rust compiler: no protoc needed.
fn main() {
    let fds = protox::compile(
        [
            "siegel/v1/identity.proto",
            "siegel/v1/delivery.proto",
            "siegel/v1/content.proto",
            "siegel/v1/reports.proto",
        ],
        ["../../proto"],
    )
    .expect("compile proto");
    prost_build::Config::new()
        .compile_fds(fds)
        .expect("generate rust");
    println!("cargo:rerun-if-changed=../../proto");
}

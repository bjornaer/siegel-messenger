// M8: starts the core (WebAssembly) from a file of our own, so the page's Content-Security-Policy
// needs no eval: flutter_rust_bridge's own loader would run `new Function`.
window.wasm_bindgen = wasm_bindgen;
window.siegelCoreReady = wasm_bindgen("pkg/rust_lib_siegel_bg.wasm");

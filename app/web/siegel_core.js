// M8: starts the core (WebAssembly) from a file of our own, so the page's Content-Security-Policy
// needs no eval: flutter_rust_bridge's own loader would run `new Function`.

// A browser that can't run Siegel Web gets a plain notice, with the reason, instead of a blank page.
window.siegelFail = function (why) {
  if (window.siegelFailed) return;
  window.siegelFailed = true;
  console.error("Siegel Web can't start:", why);
  const box = document.createElement("div");
  box.style.cssText = "font:16px/1.5 system-ui,sans-serif;max-width:32em;margin:15vh auto;padding:0 16px;color:#222";
  const h = document.createElement("h1");
  h.style.fontSize = "1.4em";
  h.textContent = "Siegel Web can't start in this browser";
  const p = document.createElement("p");
  p.textContent = "Use a current Chrome, Edge, Firefox or Safari, up to date, opened directly rather than " +
    "from a link inside another app, with hardware acceleration on. Some privacy extensions block it too.";
  const code = document.createElement("p");
  code.style.cssText = "font:13px monospace;color:#666;word-break:break-word";
  code.textContent = "Reason: " + why;
  box.append(h, p, code);
  document.body.replaceChildren(box);
};

// Anything that breaks before the app has drawn (no WebGL, say) also gets the notice.
for (const ev of ["error", "unhandledrejection"]) {
  window.addEventListener(ev, (e) => {
    if (!document.querySelector("flutter-view")) siegelFail(String(e.reason || e.message || e.error || ev));
  });
}

if (typeof WebAssembly !== "object") {
  siegelFail("no WebAssembly");
} else if (!window.crossOriginIsolated || typeof SharedArrayBuffer !== "function") {
  siegelFail("not cross-origin isolated (no SharedArrayBuffer)");
} else {
  window.wasm_bindgen = wasm_bindgen;
  window.siegelCoreReady = wasm_bindgen({ module_or_path: "pkg/rust_lib_siegel_bg.wasm" });
  window.siegelCoreReady.catch((e) => siegelFail("the core didn't load: " + e));
}

{{flutter_js}}
{{flutter_build_config}}
// M8: everything from our own origin (fonts too, mirrored at build time); no service worker,
// so a page load always runs the code the server serves now (its hashes are published).
_flutter.loader.load({
  config: { fontFallbackBaseUrl: "fonts/" },
});

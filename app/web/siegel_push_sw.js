// M8 part 6: the web app's only service worker. It caches nothing and loads no code: it shows
// that a message is waiting when the tab is closed. Pushes carry no content (MSG-17), so it
// can't say who or what; opening it brings Siegel back.
const words = {
  en: "New message",
  de: "Neue Nachricht",
  es: "Mensaje nuevo",
  pt: "Nova mensagem",
};

self.addEventListener("push", (event) => {
  const lang = (self.navigator.language || "en").slice(0, 2);
  event.waitUntil(
    self.registration.showNotification("Siegel", {
      body: words[lang] || words.en,
      tag: "siegel", // one at a time, however many arrive
      icon: "icons/Icon-192.png",
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((open) =>
      open.length ? open[0].focus() : self.clients.openWindow("./"),
    ),
  );
});

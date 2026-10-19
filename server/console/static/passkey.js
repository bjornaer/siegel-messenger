// M7 part 5: passkey enrolment and login for the moderation console (WebAuthn JSON helpers need a
// 2024-or-newer browser).
const status = (t) => (document.getElementById("status").textContent = t);

async function ceremony(begin, finish, create) {
  const res = await fetch(begin, { method: "POST" });
  if (!res.ok) return status(await res.text());
  const opts = await res.json();
  try {
    const cred = create
      ? await navigator.credentials.create({ publicKey: PublicKeyCredential.parseCreationOptionsFromJSON(opts.publicKey) })
      : await navigator.credentials.get({ publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(opts.publicKey) });
    const done = await fetch(finish, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(cred.toJSON()) });
    if (!done.ok) return status(await done.text());
    location.href = "/";
  } catch (e) {
    status("Cancelled or not available: " + e.message);
  }
}

const enrol = document.getElementById("enrol");
if (enrol) enrol.onclick = () => ceremony("/enrol/begin" + location.search, "/enrol/finish", true);
const login = document.getElementById("login");
if (login) login.onclick = () => ceremony("/login/begin", "/login/finish", false);

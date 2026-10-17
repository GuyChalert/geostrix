// TASKS.csv #621 — remembered DB passwords: encrypted, keyed per login, never stored when the OS can't encrypt.
import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
const require = createRequire(import.meta.url);
const { createDbCredentialStore } = require("../electron/dbCredentials.js");

// a stand-in for Electron's safeStorage (reversible but NOT plain text, so the file test means something)
const fakeSafe = (ok = true) => ({
  isEncryptionAvailable: () => ok,
  encryptString: (s) => Buffer.from([...Buffer.from(s, "utf8")].map((b) => b ^ 0x5a)),
  decryptString: (b) => Buffer.from([...b].map((x) => x ^ 0x5a)).toString("utf8"),
});
const login = { engine: "postgres", host: "LocalHost ", port: 54373, database: "treaty_creek", user: "geo" };

test("#621 save, read back, keyed per login, forget", () => {
  const dir = mkdtempSync(path.join(tmpdir(), "gx-cred-"));
  try {
    const st = createDbCredentialStore({ safeStorage: fakeSafe(), dir, platform: "win32" });
    assert.equal(st.has(login), false);
    assert.equal(st.set(login, "s3cret-pass"), true);
    assert.equal(st.get({ ...login, host: "localhost" }), "s3cret-pass"); // host case / spaces ignored
    assert.equal(st.get({ ...login, user: "other" }), null);              // another login: nothing
    assert.equal(st.get({ ...login, database: "harry" }), null);
    assert.ok(!readFileSync(path.join(dir, "db-credentials.json"), "utf8").includes("s3cret-pass")); // not plain text
    assert.equal(st.forget(login), true);
    assert.equal(st.has(login), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("#621 no OS encryption: nothing is saved (no plain-text fallback)", () => {
  const dir = mkdtempSync(path.join(tmpdir(), "gx-cred-"));
  try {
    const st = createDbCredentialStore({ safeStorage: fakeSafe(false), dir, platform: "win32" });
    assert.equal(st.available(), false);
    assert.equal(st.set(login, "pw"), false);
    assert.equal(st.has(login), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// TASKS.csv #640 — Linux "basic_text" (hardcoded key) reports encryption available; it must not count.
test("#640 Linux: only a real key store counts as encryption", () => {
  const dir = mkdtempSync(path.join(tmpdir(), "gx-cred-"));
  try {
    const withBackend = (b) => ({ ...fakeSafe(), getSelectedStorageBackend: () => b });
    for (const b of ["basic_text", "unknown"]) {
      const st = createDbCredentialStore({ safeStorage: withBackend(b), dir, platform: "linux" });
      assert.equal(st.available(), false, b);
      assert.equal(st.set(login, "pw"), false, b);
    }
    // an older Electron without getSelectedStorageBackend: fail closed
    assert.equal(createDbCredentialStore({ safeStorage: fakeSafe(), dir, platform: "linux" }).available(), false);
    for (const b of ["gnome_libsecret", "kwallet", "kwallet5", "kwallet6"]) {
      assert.equal(createDbCredentialStore({ safeStorage: withBackend(b), dir, platform: "linux" }).available(), true, b);
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("#640 a saved entry the key store can no longer read is not reported as saved", () => {
  const dir = mkdtempSync(path.join(tmpdir(), "gx-cred-"));
  try {
    const safe = { ...fakeSafe(), getSelectedStorageBackend: () => "gnome_libsecret" };
    assert.equal(createDbCredentialStore({ safeStorage: safe, dir, platform: "linux" }).set(login, "pw"), true);
    safe.getSelectedStorageBackend = () => "basic_text"; // e.g. next launch without a keyring
    const st = createDbCredentialStore({ safeStorage: safe, dir, platform: "linux" });
    assert.equal(st.has(login), false); // UI must not say "leave the box empty"
    assert.equal(st.get(login), null);
    assert.equal(st.forget(login), true); // but it can still be removed
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

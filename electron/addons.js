// TASKS.csv #638 — optional add-ons (first: the geoML predictive-modelling engine, GPL-3.0, addons/geoml). An add-on is a
// separate program GeoStrix downloads only when the user asks for it: a zip on GitHub Releases whose SHA-256 is pinned
// in addons/<id>/release.json (shipped inside the app), so a corrupt or tampered download is refused. It is unpacked
// into userData/addons/<id>/<version>/ and started on first use with a per-launch token, like the Python engine.
// GEOSTRIX_ADDON_<ID>_EXE (a path to the add-on's exe, or "python.exe|run_addon.py") overrides the installed copy for
// development and testing.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawn, execFile } = require("child_process");

function createAddonManager({ app, net, send }) {
  const running = {}; // id -> { proc, token, port }
  const installs = {}; // id -> { request, cancelled }

  const releaseInfo = (id) => {
    for (const base of [path.join(process.resourcesPath || "", "addons"), path.join(__dirname, "..", "addons")]) {
      try { return JSON.parse(fs.readFileSync(path.join(base, id, "release.json"), "utf8")); } catch { /* next */ }
    }
    return null;
  };
  const root = (id) => path.join(app.getPath("userData"), "addons", id);
  const installedDir = (id, info) => path.join(root(id), info.version);
  const exePath = (id, info) => path.join(installedDir(id, info), info.exe);
  const devOverride = (id) => process.env[`GEOSTRIX_ADDON_${id.toUpperCase()}_EXE`] || null;

  function status(id) {
    const info = releaseInfo(id);
    if (!info) return { id, available: false, reason: "This GeoStrix build doesn't know this add-on." };
    const dev = devOverride(id);
    const installed = !!dev || fs.existsSync(exePath(id, info));
    let sizeOnDisk = null;
    return { id, available: true, name: info.name, version: info.version, licence: info.licence, downloadBytes: info.bytes, installedBytes: info.installedBytes,
      installed, dev: !!dev, running: !!running[id], installing: !!installs[id], url: info.url, sizeOnDisk };
  }

  function download(url, dest, onProgress, state, redirects = 0) {
    return new Promise((resolve, reject) => {
      const req = net.request({ url, redirect: "manual" });
      state.request = req;
      req.on("redirect", (code, method, redirectUrl) => {
        if (redirects > 5) { req.abort(); reject(new Error("Too many redirects.")); return; }
        req.abort();
        download(redirectUrl, dest, onProgress, state, redirects + 1).then(resolve, reject);
      });
      req.on("response", (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400) return; // handled by "redirect"
        if (res.statusCode !== 200) { reject(new Error(`Download failed: HTTP ${res.statusCode}`)); return; }
        const total = Number(res.headers["content-length"]) || 0;
        const out = fs.createWriteStream(dest);
        const hash = crypto.createHash("sha256");
        let got = 0;
        res.on("data", (chunk) => { if (state.cancelled) return; out.write(chunk); hash.update(chunk); got += chunk.length; onProgress(got, total); });
        res.on("end", () => out.end(() => (state.cancelled ? reject(new Error("Cancelled.")) : resolve(hash.digest("hex")))));
        res.on("error", (e) => { out.destroy(); reject(e); });
      });
      req.on("error", reject);
      req.end();
    });
  }

  async function install(id) {
    const info = releaseInfo(id);
    if (!info?.url || !info.sha256) throw new Error("This add-on has no published download yet.");
    if (installs[id]) throw new Error("Already installing.");
    const state = (installs[id] = { cancelled: false, request: null });
    fs.mkdirSync(root(id), { recursive: true });
    const zip = path.join(root(id), `${info.version}.zip.part`);
    try {
      let last = 0;
      const sha = await download(info.url, zip, (got, total) => {
        const now = Date.now();
        if (now - last > 250 || got === total) { last = now; send({ id, phase: "download", got, total: total || info.bytes || 0 }); }
      }, state);
      if (sha !== info.sha256.toLowerCase()) throw new Error("The downloaded file doesn't match its published checksum — it was not installed. Try again later.");
      send({ id, phase: "unpack" });
      const dir = installedDir(id, info);
      fs.rmSync(dir, { recursive: true, force: true });
      fs.mkdirSync(dir, { recursive: true });
      // Windows 10+ ships bsdtar, which reads zip files
      await new Promise((resolve, reject) => execFile("tar", ["-xf", zip, "-C", dir], { windowsHide: true }, (err) => (err ? reject(new Error(`Unpacking failed: ${err.message}`)) : resolve())));
      if (!fs.existsSync(exePath(id, info))) throw new Error("The add-on was unpacked but its program is missing.");
      // older versions of this add-on are removed once the new one is in place
      for (const v of fs.readdirSync(root(id))) if (v !== info.version && !v.endsWith(".log")) fs.rmSync(path.join(root(id), v), { recursive: true, force: true });
      send({ id, phase: "done" });
      return status(id);
    } finally {
      fs.rmSync(zip, { force: true });
      delete installs[id];
    }
  }

  function cancelInstall(id) {
    const s = installs[id];
    if (!s) return false;
    s.cancelled = true;
    try { s.request?.abort(); } catch { /* already done */ }
    return true;
  }

  function stop(id) {
    const r = running[id];
    if (r?.proc && !r.proc.killed) { try { r.proc.kill(); } catch { /* gone */ } }
    delete running[id];
  }

  function uninstall(id) {
    stop(id);
    fs.rmSync(root(id), { recursive: true, force: true });
    return status(id);
  }

  function ensure(id) {
    if (running[id]) return { running: true, port: running[id].port, spawned: false };
    const info = releaseInfo(id);
    if (!info) throw new Error("Unknown add-on.");
    const dev = devOverride(id);
    let cmd, args = [];
    if (dev && dev.includes("|")) { [cmd, ...args] = dev.split("|"); }
    else { cmd = dev || exePath(id, info); }
    if (!fs.existsSync(cmd)) throw new Error("The add-on isn't installed.");
    const token = crypto.randomBytes(32).toString("hex");
    const port = info.port || 8766;
    let logFd = null;
    try {
      fs.mkdirSync(root(id), { recursive: true });
      logFd = fs.openSync(path.join(root(id), "addon.log"), "a");
      fs.writeSync(logFd, `\n=== ${id} add-on start ${new Date().toISOString()} (GeoStrix ${app.getVersion()}) ===\n`);
    } catch { logFd = null; }
    const proc = spawn(cmd, args, {
      cwd: path.dirname(args.length ? args[args.length - 1] : cmd),
      env: { ...process.env, GEOSTRIX_ADDON_TOKEN: token, GEOSTRIX_ADDON_PORT: String(port), TF_CPP_MIN_LOG_LEVEL: "2" },
      windowsHide: true,
      stdio: logFd !== null ? ["ignore", logFd, logFd] : "ignore",
    });
    running[id] = { proc, token, port };
    proc.on("exit", () => { if (running[id]?.proc === proc) delete running[id]; send({ id, phase: "stopped" }); });
    proc.on("error", () => { if (running[id]?.proc === proc) delete running[id]; });
    return { running: true, port, spawned: true };
  }

  const connection = (id) => (running[id] ? { port: running[id].port, token: running[id].token } : null);
  const stopAll = () => Object.keys(running).forEach(stop);
  return { status, install, cancelInstall, uninstall, ensure, stop, connection, stopAll };
}

module.exports = { createAddonManager };

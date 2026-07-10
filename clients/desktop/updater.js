// Auto-update resolution. The repo publishes server releases (v*) and
// client releases (client-v*) under one roof, so GitHub's "latest" cannot
// be trusted — list releases and pick the newest client one, then point
// electron-updater's generic feed at that release's download directory.
const REPO = "mjason/dala";

async function resolveLatestClient() {
  // Prefix-scoped tag listing: GitHub's /releases list is not ordered by
  // recency, so client tags drown among the (more numerous) server tags.
  const res = await fetch(`https://api.github.com/repos/${REPO}/git/matching-refs/tags/client-v`, {
    headers: { accept: "application/vnd.github+json", "user-agent": "dala-desktop" },
  });
  if (!res.ok) throw new Error(`GitHub responded with ${res.status}`);
  const refs = await res.json();
  const versions = refs
    .map((r) => String(r.ref || "").replace("refs/tags/client-v", ""))
    .filter((v) => /^\d/.test(v))
    .sort((x, y) => (isNewer(x, y) ? 1 : -1));
  const version = versions.pop();
  if (!version) return null;
  return {
    tag: `client-v${version}`,
    version,
    feedUrl: `https://github.com/${REPO}/releases/download/client-v${version}`,
  };
}

/** Semver-ish compare: is `a` newer than `b`? */
function isNewer(a, b) {
  const pa = String(a).split(".").map((n) => parseInt(n, 10) || 0);
  const pb = String(b).split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) > (pb[i] || 0);
  }
  return false;
}

module.exports = { REPO, resolveLatestClient, isNewer };

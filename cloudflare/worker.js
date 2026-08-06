/**
 * The Worker behind https://get-consolize.cybx.dev
 *
 * It exists for freshness, not for the shorter URL. raw.githubusercontent.com
 * sits behind a CDN that serves minutes-old content, which during development
 * repeatedly meant running a fix that had already been published, or concluding
 * a fix had not worked when the old file was still being served.
 *
 * So it reads through the GitHub contents API, which is not fronted by that
 * cache (measured: the API had the new commit while raw still had the old one,
 * with and without a cache-busting query string), and falls back to raw when
 * the API says no, since unauthenticated API calls are rate limited and a
 * slightly stale installer beats no installer.
 *
 * Deploy: Workers & Pages > Create > Worker, paste this, then
 * Settings > Domains & Routes > Add > Custom domain (NOT Route: a Route does
 * not create the DNS record, and the hostname simply will not resolve).
 */

const REPO = "cybx/consolize";
const REF = "main";

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path =
      url.pathname === "/" || url.pathname === "/get"
        ? "get.ps1"
        : url.pathname.replace(/^\//, "");

    // No cache at any layer: this is the fetch that has to be current.
    const noCache = { cacheTtl: 0, cacheEverything: false };

    let res = await fetch(
      `https://api.github.com/repos/${REPO}/contents/${encodeURI(path)}?ref=${REF}`,
      {
        headers: {
          // returns the file itself rather than base64 in JSON
          Accept: "application/vnd.github.raw",
          // the GitHub API rejects requests without one
          "User-Agent": "consolize-worker",
        },
        cf: noCache,
      },
    );

    if (!res.ok) {
      res = await fetch(
        `https://raw.githubusercontent.com/${REPO}/${REF}/${encodeURI(path)}`,
        { cf: noCache },
      );
    }

    if (!res.ok) {
      return new Response(`consolize: ${path} not found (${res.status})\n`, {
        status: res.status === 404 ? 404 : 502,
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }

    return new Response(res.body, {
      headers: {
        "content-type": "text/plain; charset=utf-8",
        "cache-control": "no-store",
      },
    });
  },
};

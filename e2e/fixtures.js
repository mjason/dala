// Shared Playwright fixtures.
//
// The only thing here is page health, and it is `auto` on purpose: a React
// error that unmounts a subtree leaves the DOM structurally plausible, so
// assertions about layout, text and geometry keep passing while the user is
// looking at a white screen. That is not hypothetical — a `useEffect` written
// as a bare expression adopted `scrollTo`'s return value as its cleanup, the
// whole settings modal unmounted, and all seven settings tests stayed green.
//
// So every spec gets it by importing `test`/`expect` from here instead of
// from @playwright/test. A spec that legitimately provokes an error opts out
// of THAT error, not out of the check:
//
//   test.use({ ignorePageErrors: [/MCP is enabled but/] });
const base = require("@playwright/test");
const h = require("./helpers");

const test = base.test.extend({
  /** Regexes for console errors this spec is deliberately causing. */
  ignorePageErrors: [[], { option: true }],

  pageHealth: [
    async ({ page, ignorePageErrors }, use) => {
      const failures = h.watchPageHealth(page, ignorePageErrors);
      await use(failures);
      h.assertClean(failures);
    },
    { auto: true },
  ],
});

module.exports = { ...base, test, expect: base.expect };

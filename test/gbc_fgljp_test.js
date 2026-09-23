// Unit test for gbc_fgljp.js, run with `node --test gbc_fgljp_test.js`
// (Node's own test runner, no dependencies).
//
// The script is loaded into a stub of the browser page: enough of window,
// gbc and gbcWrapper for its load-time work (query string, GBC version,
// theme service), with a GBC version below 5 so it does not start its
// wrapper and talk to fgljp. What is checked is the one place it runs code
// on a page that may have no session: onbeforeunload, which GBC's own
// test framework caught throwing on such a page.
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SCRIPT = process.env.GBC_FGLJP_JS || path.join(__dirname, '..', 'gbc_fgljp.js');

// a page with gbc_fgljp.js loaded; sessionService is what gbc.SessionService
// answers, undefined for a GBC that has none yet
function loadPage(sessionService) {
  const window = {
    location: { search: '?app=test:1' },
    gbcWrapper: { protocolVersion: 2, isPlatformTypeBrowser: () => true },
    gbc: {
      version: '3.0.0',
      ThemeService: { setValue() {} },
      SessionService: sessionService
    }
  };
  // the window is the page's global object: the script also says "fgljp"
  // and "gbc" bare, and needs the browser's URLSearchParams
  window.window = window;
  window.console = console;
  window.URLSearchParams = URLSearchParams;
  vm.runInNewContext(fs.readFileSync(SCRIPT, 'utf8'), window, { filename: SCRIPT });
  return window;
}

test('leaving a page that never got a session does not throw', () => {
  // opened for a program that is gone, or a second time for one another
  // page shows: GBC is up, its session service answers nothing
  const window = loadPage({ getCurrent: () => undefined });
  assert.strictEqual(window.onbeforeunload(), undefined);
});

test('leaving a page whose GBC has no session service at all does not throw', () => {
  const window = loadPage(undefined);
  assert.strictEqual(window.onbeforeunload(), undefined);
});

test('a page with a running application still asks before leaving', () => {
  const window = loadPage({ getCurrent: () => ({ getCurrentApplication: () => ({}) }) });
  assert.strictEqual(typeof window.onbeforeunload(), 'string');
});

const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

const source = fs.readFileSync("web/app.js", "utf8")
  .replace(/setView\(selectedView\);\s*start\(\);\s*$/, "");

function element() {
  return {
    value: "", hidden: false, disabled: false, open: false, handlers: {}, validationMessage: "",
    classList: { toggle() {} },
    addEventListener(event, handler) { this.handlers[event] = handler; },
    setCustomValidity(message) { this.validationMessage = message; },
    reportValidity() { return !this.validationMessage; },
    reset() {}, focus() {}, removeAttribute() {},
    showModal() { this.open = true; },
    close() { this.open = false; if (this.handlers.close) this.handlers.close(); }
  };
}

function harness() {
  const nodes = new Map();
  const document = {
    querySelector(selector) {
      if (!nodes.has(selector)) nodes.set(selector, element());
      return nodes.get(selector);
    },
    querySelectorAll() { return []; }
  };
  let nextID = 0;
  const context = vm.createContext({ document, URL, console, crypto: { randomUUID: () => `product-${++nextID}` } });
  vm.runInContext(source, context);
  const run = (code) => vm.runInContext(code, context);
  const node = (selector) => nodes.get(selector);
  node("#product-form").reportValidity = () =>
    Boolean(node("#product-name").value && node("#expiry-date").value)
    && node("#product-name").reportValidity();
  run("loadProducts = async () => {};");
  function fill(name = "Milk") {
    run("openForm()");
    node("#product-name").value = name;
    node("#expiry-date").value = "2026-11-07";
    node("#date-kind").value = "Use by";
  }
  async function submit() {
    // Native constraint validation precedes the browser's submit event.
    if (!node("#product-form").reportValidity()) return;
    await node("#product-form").handlers.submit({ preventDefault() {} });
  }
  return { nodes, node, run, context, fill, submit };
}

function attachStorage(h) {
  const records = new Map();
  const images = new Map();
  const state = { failWrites: false, commits: 0 };
  h.context.testDatabase = {
    transaction() {
      let aborted = false;
      let scheduled = false;
      const changes = [];
      const transaction = {
        abort() { aborted = true; this.onabort(); },
        objectStore(name) {
          const store = name === "images" ? images : records;
          function stage(change) {
            changes.push(change);
            if (scheduled) return;
            scheduled = true;
            Promise.resolve().then(() => {
              if (aborted) return;
              if (state.failWrites) {
                transaction.error = new Error("Storage full");
                transaction.abort();
                return;
              }
              changes.forEach((apply) => apply());
              state.commits++;
              transaction.oncomplete();
            });
          }
          return {
            get(id) {
              const request = {};
              Promise.resolve().then(() => {
                request.result = store.get(id);
                request.onsuccess();
              });
              return request;
            },
            add(product) { stage(() => store.set(product.id, product)); },
            put(product) { stage(() => store.set(product.id, product)); },
            delete(id) { stage(() => store.delete(id)); }
          };
        }
      };
      return transaction;
    }
  };
  h.run("database = testDatabase");
  return { records, images, state };
}

async function testDates() {
  const h = harness();
  assert.strictEqual(h.run('storedDateFromInput("2028-02-29")'), "02/29/2028");
  assert.throws(() => h.run('storedDateFromInput("2027-02-29")'), /valid expiry date/);
  assert.strictEqual(h.run('toInputDate("11/07/2026")'), "2026-11-07");
}

async function testPendingSaveAndRetry() {
  const h = harness();
  h.fill();
  h.run(`
    let writes = 0;
    let completeSave;
    let rejectSave;
    saveProduct = () => {
      writes++;
      return new Promise((resolve, reject) => { completeSave = resolve; rejectSave = reject; });
    };
  `);
  const first = h.submit();
  await h.submit();
  assert.strictEqual(h.run("writes"), 1, "duplicate submission must not write twice");
  assert.strictEqual(h.node("#save-product-button").disabled, true);
  h.node("#cancel-dialog-button").handlers.click();
  assert.strictEqual(h.node("#product-dialog").open, true);
  let prevented = false;
  h.node("#product-dialog").handlers.cancel({ preventDefault() { prevented = true; } });
  assert.strictEqual(prevented, true, "Escape must not dismiss an in-flight save");
  h.run('rejectSave(new Error("Storage full"))');
  await first;
  assert.strictEqual(h.run("isSaving"), false);
  assert.strictEqual(h.node("#save-product-button").disabled, false);
  assert.match(h.node("#form-feedback").textContent, /Storage full/);
  assert.strictEqual(h.node("#product-dialog").open, true, "write failure leaves the form open");
  const retry = h.submit();
  h.run("completeSave()");
  await retry;
  assert.strictEqual(h.run("writes"), 2);
  assert.strictEqual(h.node("#product-dialog").open, false);
  h.run("openForm()");
  assert.strictEqual(h.node("#form-feedback").textContent, "", "old form errors reset on reopen");
}

async function testNameCorrection() {
  const h = harness();
  attachStorage(h);
  h.fill("   ");
  await h.submit();
  assert.match(h.node("#product-name").validationMessage, /Enter a product name/);
  h.node("#product-name").value = "Milk";
  h.node("#product-name").handlers.input();
  assert.strictEqual(h.node("#product-form").reportValidity(), true);
  await h.submit();
  assert.strictEqual(h.node("#product-dialog").open, false);
}

async function testCommittedAddWithFailedRefresh() {
  const h = harness();
  const { records, state } = attachStorage(h);
  h.fill();
  h.run('loadProducts = async () => { throw new Error("Read unavailable"); };');
  await h.submit();
  assert.strictEqual(records.size, 1);
  assert.strictEqual(state.commits, 1);
  assert.strictEqual(h.node("#product-dialog").open, false, "committed add must not remain open for retry");
  assert.match(h.node("#feedback").textContent, /added to Active/);
  assert.match(h.node("#feedback").textContent, /changes were saved.*Reload/);
  assert.doesNotMatch(h.node("#feedback").textContent, /Could not save/);
}

async function testCommittedEditWithFailedRefresh() {
  const h = harness();
  const { records } = attachStorage(h);
  records.set("shared", { id: "shared", name: "Old name", status: "active" });
  h.fill("New name");
  h.run('editingProductId = "shared"; loadProducts = async () => { throw new Error("Read unavailable"); };');
  await h.submit();
  assert.strictEqual(records.get("shared").name, "New name");
  assert.strictEqual(records.size, 1);
  assert.strictEqual(h.node("#product-dialog").open, false);
  assert.match(h.node("#feedback").textContent, /updated.*changes were saved/);
}

async function testFailedAddCanRetry() {
  const h = harness();
  const { records, state } = attachStorage(h);
  h.fill();
  state.failWrites = true;
  await h.submit();
  assert.strictEqual(records.size, 0);
  assert.strictEqual(h.node("#product-dialog").open, true);
  assert.match(h.node("#form-feedback").textContent, /Storage full/);
  state.failWrites = false;
  await h.submit();
  assert.strictEqual(records.size, 1);
  assert.strictEqual(h.node("#product-dialog").open, false);
}

async function testCrossTabAndCommittedMutations() {
  const h = harness();
  const { records } = attachStorage(h);
  records.set("shared", { id: "shared", name: "Edited in another tab", status: "active" });
  h.run('products = [{ id: "shared", name: "Stale name", status: "active" }];');
  h.run('loadProducts = async () => { throw new Error("Read unavailable"); };');
  await h.run('moveToRepurchase("shared", "Consumed")');
  assert.strictEqual(records.get("shared").name, "Edited in another tab");
  assert.strictEqual(records.get("shared").status, "toBuyAgain");
  assert.match(h.node("#feedback").textContent, /moved to To Buy Again.*changes were saved/);
  await h.run('removeProduct("shared")');
  assert.strictEqual(records.has("shared"), false);
  assert.match(h.node("#feedback").textContent, /removed from To Buy Again.*changes were saved/);
  await h.run('moveToRepurchase("shared", "Thrown")');
  assert.strictEqual(records.has("shared"), false, "deleted records must not be recreated");
  assert.match(h.node("#feedback").textContent, /no longer available/);
}

async function main() {
  const html = fs.readFileSync("web/index.html", "utf8");
  const dialog = html.slice(html.indexOf('<dialog id="product-dialog"'), html.indexOf("</dialog>"));
  assert.match(dialog, /id="form-feedback" role="alert"/, "save errors must be announced inside the modal");
  await testDates();
  await testPendingSaveAndRetry();
  await testNameCorrection();
  await testCommittedAddWithFailedRefresh();
  await testCommittedEditWithFailedRefresh();
  await testFailedAddCanRetry();
  await testCrossTabAndCommittedMutations();
  console.log("Web regression checks passed.");
}

main().catch((error) => { console.error(error); process.exitCode = 1; });

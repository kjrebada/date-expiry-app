"use strict";

const DATABASE_NAME = "expiry-tracker";
const DATABASE_VERSION = 1;
const PRODUCT_STORE = "products";
const IMAGE_STORE = "images";
const THREE_DAYS = 3;
const MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const elements = {
  addButton: document.querySelector("#add-product-button"),
  feedback: document.querySelector("#feedback"),
  formFeedback: document.querySelector("#form-feedback"),
  tabs: [...document.querySelectorAll(".tab")],
  views: [...document.querySelectorAll(".view-panel")],
  activeContent: document.querySelector("#active-content"),
  activeCount: document.querySelector("#active-count"),
  repurchaseContent: document.querySelector("#repurchase-content"),
  repurchaseCount: document.querySelector("#repurchase-count"),
  dialog: document.querySelector("#product-dialog"),
  formHeading: document.querySelector("#form-heading"),
  saveButton: document.querySelector("#save-product-button"),
  form: document.querySelector("#product-form"),
  name: document.querySelector("#product-name"),
  date: document.querySelector("#expiry-date"),
  dateKind: document.querySelector("#date-kind"),
  file: document.querySelector("#product-image"),
  imageFields: document.querySelector("#image-fields"),
  preview: document.querySelector("#image-preview"),
  previewImage: document.querySelector("#preview-image")
};

let database;
let products = [];
let imageURLs = new Map();
let selectedImage = null;
let previewURL = null;
let selectedView = "active";
let editingProductId = null;
let isSaving = false;

function showMessage(message, isError = false) {
  elements.feedback.textContent = message;
  elements.feedback.classList.toggle("is-error", isError);
}

function showFormMessage(message) {
  elements.formFeedback.textContent = message;
}

async function refreshAfterCommit(successMessage) {
  // A completed write is durable even when the subsequent list refresh fails.
  try {
    await loadProducts();
    showMessage(successMessage);
  } catch (error) {
    showMessage(`${successMessage} Your changes were saved, but the list could not refresh. Reload this page to see them. ${error.message}`, true);
  }
}

function openDatabase() {
  return new Promise((resolve, reject) => {
    if (!("indexedDB" in window)) {
      reject(new Error("This browser does not support IndexedDB, which is required to save products."));
      return;
    }

    const request = indexedDB.open(DATABASE_NAME, DATABASE_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(PRODUCT_STORE)) {
        db.createObjectStore(PRODUCT_STORE, { keyPath: "id" });
      }
      if (!db.objectStoreNames.contains(IMAGE_STORE)) {
        db.createObjectStore(IMAGE_STORE, { keyPath: "id" });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("Could not open browser storage."));
    request.onblocked = () => reject(new Error("Browser storage is blocked by another open tracker tab. Close other tabs and reload."));
  });
}

function transactionComplete(transaction) {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error || new Error("Browser storage transaction failed."));
    transaction.onabort = () => reject(transaction.error || new Error("Browser storage transaction was aborted."));
  });
}

function requestResult(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("Could not read browser storage."));
  });
}

function isValidCalendarDay(year, month, day) {
  if (!Number.isInteger(year) || year < 1 || year > 9999
      || !Number.isInteger(month) || month < 1 || month > 12
      || !Number.isInteger(day) || day < 1) return false;
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysPerMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= daysPerMonth[month - 1];
}

function utcDayNumber(year, month, day) {
  const date = new Date(0);
  date.setUTCHours(0, 0, 0, 0);
  date.setUTCFullYear(year, month - 1, day);
  return date.getTime();
}

async function loadProducts() {
  const transaction = database.transaction([PRODUCT_STORE, IMAGE_STORE], "readonly");
  const done = transactionComplete(transaction);
  const productRequest = transaction.objectStore(PRODUCT_STORE).getAll();
  const imageRequest = transaction.objectStore(IMAGE_STORE).getAll();
  const [storedProducts, storedImages] = await Promise.all([
    requestResult(productRequest),
    requestResult(imageRequest),
    done
  ]);

  for (const url of imageURLs.values()) URL.revokeObjectURL(url);
  imageURLs = new Map(storedImages.map(({ id, blob }) => [id, URL.createObjectURL(blob)]));
  products = storedProducts;
  render();
}

function localDayString(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function toInputDate(value) {
  if (typeof value !== "string" || !/^\d{2}\/\d{2}\/\d{4}$/.test(value)) {
    throw new Error("A saved product has an invalid expiry date.");
  }
  const [month, day, year] = value.split("/").map(Number);
  if (!isValidCalendarDay(year, month, day)) {
    throw new Error("A saved product has an invalid expiry date.");
  }
  return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

function storedDateFromInput(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error("Choose a valid expiry date.");
  const [year, month, day] = value.split("-").map(Number);
  if (!isValidCalendarDay(year, month, day)) {
    throw new Error("Choose a valid expiry date.");
  }
  return `${String(month).padStart(2, "0")}/${String(day).padStart(2, "0")}/${String(year).padStart(4, "0")}`;
}

function formatDate(value) {
  const [year, month, day] = value.split("-").map(Number);
  return `${String(day).padStart(2, "0")} ${MONTH_NAMES[month - 1]} ${String(year).padStart(4, "0")}`;
}

function expiryState(product) {
  let date;
  try {
    date = toInputDate(product.expiryDate);
  } catch {
    return { label: "Date unavailable", className: "neutral" };
  }
  const [year, month, day] = date.split("-").map(Number);
  const expiryDay = utcDayNumber(year, month, day);
  const [todayYear, todayMonth, todayDay] = localDayString().split("-").map(Number);
  const today = utcDayNumber(todayYear, todayMonth, todayDay);
  const daysUntil = Math.round((expiryDay - today) / 86_400_000);
  if (daysUntil < 0) return { label: "Overdue", className: "overdue" };
  if (daysUntil <= THREE_DAYS) return { label: daysUntil === 0 ? "Due today" : "Due soon", className: "soon" };
  return { label: "Upcoming", className: "ok" };
}

function sortedActive() {
  return products
    .filter((product) => product.status === "active")
    .sort((a, b) => {
      try {
        return toInputDate(a.expiryDate).localeCompare(toInputDate(b.expiryDate));
      } catch {
        return String(a.expiryDate).localeCompare(String(b.expiryDate));
      }
    });
}

function makeElement(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}

function makeImage(product, className) {
  const src = imageURLs.get(product.id);
  if (!src) return null;
  const image = makeElement("img", className);
  image.src = src;
  image.alt = `${product.name} product image`;
  return image;
}

function makeAction(label, action, className = "", accessibleLabel = label) {
  const button = makeElement("button", `small-button ${className}`.trim(), label);
  button.type = "button";
  button.setAttribute("aria-label", accessibleLabel);
  button.addEventListener("click", action);
  return button;
}

function emptyState(title, message) {
  const wrapper = makeElement("div", "empty-state");
  wrapper.append(makeElement("h3", "", title), makeElement("p", "", message));
  return wrapper;
}

function makeStatusBadge(product) {
  const state = expiryState(product);
  return makeElement("span", `badge ${state.className}`, state.label);
}

function makeActiveRow(product) {
  const row = document.createElement("tr");
  const productCell = document.createElement("td");
  const productName = makeElement("div", "product-name");
  const image = makeImage(product, "thumbnail");
  if (image) productName.append(image);
  const nameText = document.createElement("span");
  nameText.append(makeElement("strong", "", product.name), makeElement("span", "kind", product.dateKind));
  productName.append(nameText);
  productCell.append(productName);

  const dateCell = makeElement("td", "date-cell", safeDisplayDate(product.expiryDate));
  const stateCell = document.createElement("td");
  stateCell.append(makeStatusBadge(product));
  const actionsCell = document.createElement("td");
  const actions = makeElement("div", "row-actions");
  actions.append(
    makeAction("Edit", () => openEditForm(product), "edit", `Edit ${product.name}`),
    makeAction("Consumed", () => moveToRepurchase(product.id, "Consumed")),
    makeAction("Thrown", () => moveToRepurchase(product.id, "Thrown"))
  );
  actionsCell.append(actions);
  row.append(productCell, dateCell, stateCell, actionsCell);
  return row;
}

function safeDisplayDate(value) {
  try {
    return formatDate(toInputDate(value));
  } catch {
    return "Invalid date";
  }
}

function makeActiveTable(active) {
  const wrapper = makeElement("div", "table-wrap");
  const table = document.createElement("table");
  const head = document.createElement("thead");
  const headerRow = document.createElement("tr");
  for (const label of ["Product", "Expiry date", "Status", "Actions"]) {
    headerRow.append(makeElement("th", "", label));
  }
  head.append(headerRow);
  const body = document.createElement("tbody");
  for (const product of active) body.append(makeActiveRow(product));
  table.append(head, body);
  wrapper.append(table);
  return wrapper;
}

function makeRepurchaseRow(product) {
  const row = document.createElement("tr");
  const productCell = document.createElement("td");
  const productName = makeElement("div", "product-name");
  const image = makeImage(product, "thumbnail");
  if (image) productName.append(image);
  productName.append(makeElement("span", "", product.name));
  productCell.append(productName);
  const dispositionCell = makeElement("td", "", product.lastDisposition || "-");
  const dateCell = makeElement("td", "date-cell", safeDisplayDate(product.expiryDate));
  const actionsCell = document.createElement("td");
  actionsCell.append(makeAction("Remove", () => removeProduct(product.id), "danger"));
  row.append(productCell, dispositionCell, dateCell, actionsCell);
  return row;
}

function makeRepurchaseTable(items) {
  const wrapper = makeElement("div", "table-wrap");
  const table = document.createElement("table");
  const head = document.createElement("thead");
  const headerRow = document.createElement("tr");
  for (const label of ["Product", "Last marked", "Expiry date", "Action"]) {
    headerRow.append(makeElement("th", "", label));
  }
  head.append(headerRow);
  const body = document.createElement("tbody");
  for (const product of items) body.append(makeRepurchaseRow(product));
  table.append(head, body);
  wrapper.append(table);
  return wrapper;
}

function render() {
  const active = sortedActive();
  const repurchase = products.filter((product) => product.status === "toBuyAgain");
  elements.activeCount.textContent = `${active.length} ${active.length === 1 ? "product" : "products"}`;
  elements.repurchaseCount.textContent = `${repurchase.length} ${repurchase.length === 1 ? "product" : "products"}`;

  elements.activeContent.replaceChildren(active.length
    ? makeActiveTable(active)
    : emptyState("Nothing expiring yet", "Add a product to start your expiry list."));
  elements.repurchaseContent.replaceChildren(repurchase.length
    ? makeRepurchaseTable(repurchase)
    : emptyState("Your list is empty", "Products marked Consumed or Thrown appear here."));
}

async function saveProduct(product) {
  const transaction = database.transaction([PRODUCT_STORE, IMAGE_STORE], "readwrite");
  const done = transactionComplete(transaction);
  transaction.objectStore(PRODUCT_STORE).add(product);
  if (selectedImage) {
    transaction.objectStore(IMAGE_STORE).add({ id: product.id, blob: selectedImage });
  }
  await done;
}

async function updateActiveProduct(id, fields) {
  const transaction = database.transaction(PRODUCT_STORE, "readwrite");
  const done = transactionComplete(transaction);
  const store = transaction.objectStore(PRODUCT_STORE);
  let updateError = null;
  const request = store.get(id);
  request.onsuccess = () => {
    const product = request.result;
    if (!product || product.status !== "active") {
      updateError = new Error("That active product is no longer available.");
      transaction.abort();
      return;
    }
    store.put({ ...product, ...fields });
  };
  request.onerror = () => {
    updateError = request.error || new Error("Could not read the product before updating it.");
  };
  try {
    await done;
  } catch (error) {
    throw updateError || error;
  }
}

async function moveToRepurchase(id, disposition) {
  try {
    const product = products.find((item) => item.id === id);
    if (!product) throw new Error("That product is no longer available.");
    // Read and update in one transaction so another tab's edits are preserved,
    // and a product deleted in another tab cannot be recreated from stale UI state.
    await updateActiveProduct(id, { status: "toBuyAgain", lastDisposition: disposition });
    await refreshAfterCommit(`${product.name} moved to To Buy Again.`);
  } catch (error) {
    showMessage(`Could not update product: ${error.message}`, true);
  }
}

async function removeProduct(id) {
  try {
    const product = products.find((item) => item.id === id);
    if (!product) throw new Error("That product is no longer available.");
    const transaction = database.transaction([PRODUCT_STORE, IMAGE_STORE], "readwrite");
    const done = transactionComplete(transaction);
    transaction.objectStore(PRODUCT_STORE).delete(id);
    transaction.objectStore(IMAGE_STORE).delete(id);
    await done;
    await refreshAfterCommit(`${product.name} removed from To Buy Again.`);
  } catch (error) {
    showMessage(`Could not remove product: ${error.message}`, true);
  }
}

function setView(view) {
  selectedView = view;
  for (const tab of elements.tabs) {
    const selected = tab.dataset.view === view;
    tab.classList.toggle("is-selected", selected);
    if (selected) tab.setAttribute("aria-current", "page");
    else tab.removeAttribute("aria-current");
  }
  for (const panel of elements.views) panel.hidden = panel.id !== `${view}-view`;
}

function resetImageInput() {
  selectedImage = null;
  elements.file.value = "";
  elements.preview.hidden = true;
  elements.previewImage.removeAttribute("src");
  if (previewURL) URL.revokeObjectURL(previewURL);
  previewURL = null;
}

function openForm() {
  if (isSaving) return;
  showFormMessage("");
  elements.name.setCustomValidity("");
  elements.form.reset();
  resetImageInput();
  editingProductId = null;
  elements.formHeading.textContent = "Add product";
  elements.saveButton.textContent = "Save product";
  elements.imageFields.hidden = false;
  elements.dialog.showModal();
  elements.name.focus();
}

function openEditForm(product) {
  if (isSaving || product.status !== "active") return;
  showFormMessage("");
  elements.name.setCustomValidity("");
  elements.form.reset();
  resetImageInput();
  editingProductId = product.id;
  elements.formHeading.textContent = "Edit product";
  elements.saveButton.textContent = "Save changes";
  elements.imageFields.hidden = true;
  elements.name.value = product.name;
  elements.dateKind.value = product.dateKind;
  try {
    elements.date.value = toInputDate(product.expiryDate);
  } catch (error) {
    showMessage(`Could not edit product: ${error.message}`, true);
    editingProductId = null;
    elements.imageFields.hidden = false;
    return;
  }
  elements.dialog.showModal();
  elements.name.focus();
}

elements.name.addEventListener("input", () => {
  elements.name.setCustomValidity("");
});

elements.addButton.addEventListener("click", openForm);
for (const tab of elements.tabs) tab.addEventListener("click", () => setView(tab.dataset.view));
document.querySelector("#close-dialog-button").addEventListener("click", () => { if (!isSaving) elements.dialog.close(); });
document.querySelector("#cancel-dialog-button").addEventListener("click", () => { if (!isSaving) elements.dialog.close(); });
elements.dialog.addEventListener("cancel", (event) => {
  if (isSaving) event.preventDefault();
});
elements.dialog.addEventListener("close", () => {
  editingProductId = null;
  elements.imageFields.hidden = false;
});
document.querySelector("#remove-image-button").addEventListener("click", resetImageInput);

elements.file.addEventListener("change", () => {
  const file = elements.file.files[0];
  if (!file) {
    resetImageInput();
    return;
  }
  if (file.type && !file.type.startsWith("image/")) {
    resetImageInput();
    showFormMessage("Choose an image file.");
    return;
  }
  selectedImage = file;
  if (previewURL) URL.revokeObjectURL(previewURL);
  previewURL = URL.createObjectURL(file);
  elements.previewImage.src = previewURL;
  elements.preview.hidden = false;
  showFormMessage("");
});

elements.form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (isSaving) return;
  showFormMessage("");
  elements.name.setCustomValidity("");
  if (!elements.form.reportValidity()) return;
  const name = elements.name.value.trim();
  if (!name) {
    elements.name.setCustomValidity("Enter a product name.");
    elements.name.reportValidity();
    return;
  }
  elements.name.setCustomValidity("");

  isSaving = true;
  elements.saveButton.disabled = true;
  try {
    if (!["Use by", "Best before"].includes(elements.dateKind.value)) {
      throw new Error("Choose Use by or Best before.");
    }
    const updatedFields = {
      name,
      expiryDate: storedDateFromInput(elements.date.value),
      dateKind: elements.dateKind.value
    };
    const isEditing = Boolean(editingProductId);
    if (isEditing) {
      const productId = editingProductId;
      await updateActiveProduct(productId, updatedFields);
    } else {
      const product = {
        id: crypto.randomUUID(),
        ...updatedFields,
        status: "active"
      };
      await saveProduct(product);
    }
    elements.dialog.close();
    resetImageInput();
    setView("active");
    await refreshAfterCommit(isEditing ? `${name} updated.` : `${name} added to Active.`);
  } catch (error) {
    showFormMessage(`Could not save product: ${error.message}`);
  } finally {
    isSaving = false;
    elements.saveButton.disabled = false;
  }
});

async function start() {
  try {
    database = await openDatabase();
    database.onversionchange = () => {
      database.close();
      showMessage("Storage was updated in another tab. Reload this page to continue.", true);
    };
    await loadProducts();
  } catch (error) {
    showMessage(`Browser storage unavailable: ${error.message}`, true);
    elements.addButton.disabled = true;
    elements.addButton.title = "Products cannot be saved until browser storage is available.";
  }
}

setView(selectedView);
start();

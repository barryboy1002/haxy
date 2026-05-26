const grid = document.getElementById("grid");
const pageJsonBase64 = document.getElementById("page").textContent;

let wasmInstance;
const decoder = new TextDecoder();
const encoder = new TextEncoder();
let currentHtml = "";

const MIN_COLS = 30;

// measured once after the font is loaded. recomputed lazily if it ever
// reads back as zero (e.g. measured before the font was actually ready).
let cellWidth = null;

function measureCellWidth() {
    const probe = document.createElement("span");
    probe.style.position = "absolute";
    probe.style.visibility = "hidden";
    probe.style.whiteSpace = "pre";
    probe.textContent = "X".repeat(100);
    grid.appendChild(probe);
    const w = probe.getBoundingClientRect().width / 100;
    probe.remove();
    return w;
}

function maxCols() {
    if (!cellWidth) cellWidth = measureCellWidth();
    return Math.max(MIN_COLS, Math.floor(document.body.clientWidth / cellWidth));
}

function readWasmString(ptr, len) {
    const memory = wasmInstance.exports.memory;
    return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
}

const importObject = {
    env: {
        _consoleLog: function (ptr, len) {
            console.log(readWasmString(ptr, len));
        },
        _setHtml: function (ptr, len) {
            const html = readWasmString(ptr, len);
            if (html === currentHtml) return;
            currentHtml = html;
            // capture which focusable element had focus + (for inputs) its
            // cursor position so we can restore it after innerHTML wipes
            // and re-creates the elements. covers both overlay inputs AND
            // tabbable submit-button spans; otherwise focus on the latter
            // would be lost on every re-render, and Enter would fall
            // through to the wasm key dispatch instead of being intercepted
            // as a form submission.
            const active = document.activeElement;
            let savedFocusId = null;
            let savedStart = null;
            let savedEnd = null;
            if (active && active.dataset && active.dataset.focusId) {
                savedFocusId = active.dataset.focusId;
                if (active.tagName === "INPUT") {
                    savedStart = active.selectionStart;
                    savedEnd = active.selectionEnd;
                }
            }
            grid.innerHTML = html;
            if (savedFocusId !== null) {
                const restored = grid.querySelector(`[data-focus-id="${savedFocusId}"]`);
                if (restored && typeof restored.focus === "function") {
                    restored.focus();
                    if (savedStart !== null && restored.setSelectionRange) {
                        try { restored.setSelectionRange(savedStart, savedEnd); } catch (_) {}
                    }
                }
            }
        },
    },
};

function sendTextInputValue(focusId, value) {
    const bytes = encoder.encode(value);
    const ptr = wasmInstance.exports._alloc(bytes.length);
    new Uint8Array(wasmInstance.exports.memory.buffer, ptr, bytes.length).set(bytes);
    wasmInstance.exports._setTextInputValue(focusId, ptr, bytes.length);
    wasmInstance.exports._tick(maxCols());
}

// POST the current input values to the server form route. on response (any
// status) we navigate to / so the server can render the page with whatever
// session cookie it just set.
function submitForm(url) {
    const params = new URLSearchParams();
    const inputs = grid.querySelectorAll("input");
    for (const input of inputs) {
        if (input.name) params.append(input.name, input.value);
    }
    fetch(url, { method: "POST", body: params, redirect: "manual", credentials: "same-origin" })
        .finally(() => { window.location.href = "/"; });
}

WebAssembly.instantiateStreaming(fetch("haxy.wasm"), importObject).then(async (result) => {
    wasmInstance = result.instance;

    // wait for the @font-face to load before measuring cell width, otherwise
    // we get the fallback font's metrics.
    if (document.fonts && document.fonts.ready) {
        await document.fonts.ready;
    }

    // the page is embedded as base64 so it can sit inside the host html
    // without worrying about characters that would terminate the script tag.
    // decode here and hand the raw json bytes to the wasm.
    const jsonBytes = Uint8Array.from(atob(pageJsonBase64), (c) => c.charCodeAt(0));
    const ptr = wasmInstance.exports._alloc(jsonBytes.length);
    new Uint8Array(wasmInstance.exports.memory.buffer, ptr, jsonBytes.length).set(jsonBytes);
    wasmInstance.exports._start(ptr, jsonBytes.length, maxCols());

    document.addEventListener("keydown", (event) => {
        // when an overlay input owns focus, the browser handles typing &
        // cursor movement natively; wasm gets the new value via input events
        // instead of per-key dispatch. don't forward, and don't intercept
        // arrow / home / end which the input needs for cursor movement.
        // exception: Enter triggers form submission when one is on the page.
        if (document.activeElement && document.activeElement.tagName === "INPUT") {
            if (event.key === "Enter") {
                event.preventDefault();
                const submitSpan = grid.querySelector('[data-action="submit"]');
                if (submitSpan) {
                    submitForm(submitSpan.dataset.url);
                }
            }
            return;
        }
        // a focused submit-button span (Tab can land here now that it has a
        // tabindex) should submit on Enter the same as a click does.
        if (event.key === "Enter" && document.activeElement && document.activeElement.dataset && document.activeElement.dataset.action === "submit") {
            event.preventDefault();
            submitForm(document.activeElement.dataset.url);
            return;
        }
        if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Home", "End"].includes(event.key)) {
            event.preventDefault();
        }
        wasmInstance.exports._onKeyDown(event.keyCode);
        wasmInstance.exports._tick(maxCols());
    });

    // event delegation: each render rebuilds the input elements (innerHTML
    // wipe), so we can't attach listeners per-input. delegating on grid
    // catches inputs created at any point.
    grid.addEventListener("input", (event) => {
        const t = event.target;
        if (!t || t.tagName !== "INPUT" || !t.dataset.focusId) return;
        sendTextInputValue(Number(t.dataset.focusId), t.value);
    });

    grid.addEventListener("focusin", (event) => {
        const t = event.target;
        if (!t || !t.dataset || !t.dataset.focusId) return;
        wasmInstance.exports._onMouseClick(Number(t.dataset.focusId));
        wasmInstance.exports._tick(maxCols());
    });

    grid.addEventListener("click", (event) => {
        const span = event.target.closest(".clickable");
        if (!span) return;
        if (span.dataset.action === "submit") {
            event.preventDefault();
            submitForm(span.dataset.url);
            return;
        }
        const focusId = Number(span.dataset.focusId);
        wasmInstance.exports._onMouseClick(focusId);
        // synthesize Enter so the focused widget's "activate" handler fires
        // (e.g. a button click runs its submit handler). widgets that don't
        // care about Enter just ignore it.
        wasmInstance.exports._onKeyDown(13);
        wasmInstance.exports._tick(maxCols());
    });

    let resizeTimer = null;
    window.addEventListener("resize", () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => {
            wasmInstance.exports._tick(maxCols());
        }, 100);
    });
});

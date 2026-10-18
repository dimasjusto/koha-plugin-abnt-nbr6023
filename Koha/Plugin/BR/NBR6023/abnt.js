/* Plugin Referencia ABNT (NBR 6023) \u2014 botao e janela na pagina do registro.
   Funciona no OPAC (opac-detail) e na intranet (catalogue/detail). Sem depend\u00eancias. */
(function () {
  "use strict";
  var cfg = window.ABNT_CFG || {};
  var params = new URLSearchParams(window.location.search);
  var biblio = params.get("biblionumber");
  var isOpac = document.body && document.body.id === "opac-detail";
  var isStaff = document.body && document.body.id === "catalog_detail";
  if (!biblio || !(isOpac || isStaff)) return;

  var css =
    ".abnt-overlay{position:fixed;inset:0;background:rgba(15,20,28,.55);display:flex;align-items:center;justify-content:center;z-index:10000;padding:16px}" +
    ".abnt-box{background:#fff;color:#1d2531;max-width:720px;width:100%;border-radius:8px;box-shadow:0 12px 40px rgba(0,0,0,.3);padding:20px 22px;font-family:inherit}" +
    ".abnt-box h2{font-size:1.15rem;margin:0 0 12px;display:flex;justify-content:space-between;align-items:center;gap:12px}" +
    ".abnt-close{background:none;border:0;font-size:1.5rem;line-height:1;cursor:pointer;color:#5d6878}" +
    ".abnt-modes{display:flex;gap:16px;margin:0 0 12px;font-size:.9rem}" +
    ".abnt-ref{font-family:Georgia,'Times New Roman',serif;font-size:1.05rem;line-height:1.55;background:#f5f6f8;border:1px solid #dde1e7;border-radius:6px;padding:14px 16px;margin:0;overflow-wrap:anywhere}" +
    ".abnt-warn{margin:10px 0 0;padding:8px 12px 8px 26px;background:#fbf3e2;color:#7a5000;border-radius:4px;font-size:.85rem}" +
    ".abnt-actions{display:flex;gap:10px;justify-content:flex-end;align-items:center;margin-top:14px}" +
    ".abnt-msg{font-size:.85rem;color:#2a5b86;margin-right:auto}" +
    ".abnt-note{font-size:.8rem;color:#5d6878;margin:8px 0 0}";

  function el(tag, attrs, html) {
    var e = document.createElement(tag);
    for (var k in attrs || {}) e.setAttribute(k, attrs[k]);
    if (html != null) e.innerHTML = html;
    return e;
  }

  var current = { html: "", text: "" };

  function load(mode, box) {
    var ref = box.querySelector(".abnt-ref");
    var warn = box.querySelector(".abnt-warn");
    ref.textContent = "Gerando a refer\u00eancia\u2026";
    if (warn) warn.remove();
    fetch(cfg.api + encodeURIComponent(biblio) + "/reference?mode=" + encodeURIComponent(mode), {
      headers: { Accept: "application/json" },
      credentials: "same-origin"
    })
      .then(function (r) {
        return r.json().then(function (j) { return { ok: r.ok, j: j }; });
      })
      .then(function (res) {
        if (!res.ok) throw new Error(res.j && res.j.error ? res.j.error : "Erro ao gerar a refer\u00eancia.");
        current = { html: res.j.html, text: res.j.text };
        ref.innerHTML = res.j.html; // HTML ja escapado pelo servidor
        if (cfg.staff && res.j.warnings && res.j.warnings.length) {
          var ul = el("ul", { class: "abnt-warn" });
          res.j.warnings.forEach(function (w) { var li = el("li"); li.textContent = w; ul.appendChild(li); });
          ref.insertAdjacentElement("afterend", ul);
        }
      })
      .catch(function (e) { ref.textContent = e.message; });
  }

  function copy(box) {
    var msg = box.querySelector(".abnt-msg");
    var done = function () { msg.textContent = "Refer\u00eancia copiada."; };
    var fallback = function () {
      var r = document.createRange();
      r.selectNodeContents(box.querySelector(".abnt-ref"));
      var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      try { document.execCommand("copy"); done(); } catch (e) { msg.textContent = "Selecione o texto e copie com Ctrl+C."; }
    };
    // Copia em HTML (mantem negrito e italico ao colar no editor de texto) e em texto puro
    if (navigator.clipboard && window.ClipboardItem) {
      var item = new ClipboardItem({
        "text/html": new Blob([current.html], { type: "text/html" }),
        "text/plain": new Blob([current.text], { type: "text/plain" })
      });
      navigator.clipboard.write([item]).then(done, fallback);
    } else if (navigator.clipboard) {
      navigator.clipboard.writeText(current.text).then(done, fallback);
    } else {
      fallback();
    }
  }

  function open() {
    var mode = cfg.defaultMode || "essencial";
    var overlay = el("div", { class: "abnt-overlay", role: "dialog", "aria-modal": "true", "aria-label": cfg.label });
    var modes = cfg.allowMode
      ? '<div class="abnt-modes" role="radiogroup">' +
        '<label><input type="radio" name="abnt-mode" value="essencial"' + (mode === "essencial" ? " checked" : "") + "> Elementos essenciais</label>" +
        '<label><input type="radio" name="abnt-mode" value="completo"' + (mode === "completo" ? " checked" : "") + "> Com elementos complementares</label></div>"
      : "";
    var box = el("div", { class: "abnt-box" },
      "<h2><span></span><button type=\"button\" class=\"abnt-close\" aria-label=\"Fechar\">&times;</button></h2>" +
      modes +
      '<p class="abnt-ref"></p>' +
      '<p class="abnt-note">ABNT NBR 6023:2025. Confira com o documento antes de usar.</p>' +
      '<div class="abnt-actions"><span class="abnt-msg" aria-live="polite"></span>' +
      '<button type="button" class="btn btn-primary abnt-copy">Copiar</button>' +
      '<button type="button" class="btn btn-default btn-secondary abnt-cancel">Fechar</button></div>');
    box.querySelector("h2 span").textContent = cfg.label;
    overlay.appendChild(box);
    document.body.appendChild(overlay);

    var close = function () { overlay.remove(); document.removeEventListener("keydown", onKey); };
    var onKey = function (e) { if (e.key === "Escape") close(); };
    document.addEventListener("keydown", onKey);
    overlay.addEventListener("click", function (e) { if (e.target === overlay) close(); });
    box.querySelector(".abnt-close").addEventListener("click", close);
    box.querySelector(".abnt-cancel").addEventListener("click", close);
    box.querySelector(".abnt-copy").addEventListener("click", function () { copy(box); });
    box.querySelectorAll('input[name="abnt-mode"]').forEach(function (r) {
      r.addEventListener("change", function () { box.querySelector(".abnt-msg").textContent = ""; load(r.value, box); });
    });
    box.querySelector(".abnt-copy").focus();
    load(mode, box);
  }

  // OPAC: insere "ABNT" no modal "Citar" (#citeModal), que o Koha monta como pares
  // <h2>Estilo</h2><p>citacao</p> em ordem alfabetica. A referencia e buscada ao abrir o modal.
  function addToCiteModal() {
    var body = document.querySelector("#citeModal .modal-body");
    if (!body) return false;
    var heads = Array.prototype.filter.call(body.children, function (n) { return /^H[1-6]$/.test(n.tagName); });
    var tag = heads.length ? heads[0].tagName.toLowerCase() : "h2";
    var h = el(tag, { "data-abnt": "1" });
    h.textContent = cfg.citeLabel || "ABNT";
    var p = el("p", { "data-abnt": "1", class: "abnt-cite" });
    var next = null;
    for (var i = 0; i < heads.length; i++) {
      if (heads[i].textContent.trim().localeCompare(h.textContent, "pt-BR", { sensitivity: "base" }) > 0) { next = heads[i]; break; }
    }
    body.insertBefore(h, next);
    body.insertBefore(p, next);

    var loaded = false;
    var fill = function () {
      if (loaded) return;
      loaded = true;
      p.textContent = "Gerando a refer\u00eancia\u2026";
      fetch(cfg.api + encodeURIComponent(biblio) + "/reference?mode=" + encodeURIComponent(cfg.defaultMode || "essencial"), {
        headers: { Accept: "application/json" }, credentials: "same-origin"
      })
        .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
        .then(function (res) {
          if (!res.ok) throw new Error(res.j && res.j.error ? res.j.error : "Erro ao gerar a refer\u00eancia.");
          p.innerHTML = res.j.html; // HTML ja escapado pelo servidor
        })
        .catch(function (e) { p.textContent = e.message; loaded = false; });
    };
    var modal = document.getElementById("citeModal");
    modal.addEventListener("show.bs.modal", fill);          // Bootstrap 5
    if (window.jQuery) window.jQuery(modal).on("show.bs.modal", fill); // Bootstrap 4 (temas antigos)
    var trigger = document.getElementById("cite");
    if (trigger) trigger.addEventListener("click", fill);
    return true;
  }

  function addButton() {
    var style = el("style", {}, css);
    document.head.appendChild(style);
    var icon = '<i class="fa fa-fw fa-quote-left" aria-hidden="true"></i> ';
    if (isOpac && cfg.opacInCite && addToCiteModal()) return;
    if (isOpac) {
      // Sem o modal "Citar": lista "Acoes" da barra lateral; se nao existir, logo apos o titulo
      var ul = document.querySelector("#action");
      var a = el("a", { href: "#", class: "abnt-btn" }, icon + "<span></span>");
      a.querySelector("span").textContent = cfg.label;
      if (ul) { var li = el("li"); li.appendChild(a); ul.appendChild(li); }
      else {
        var t = document.querySelector("h1.title, h2.title, #catalogue_detail_biblio h1");
        if (!t) return;
        t.insertAdjacentElement("afterend", a);
      }
      a.addEventListener("click", function (e) { e.preventDefault(); open(); });
    } else {
      var bar = document.querySelector("#toolbar");
      if (!bar) return;
      var b = el("button", { type: "button", class: "btn btn-default abnt-btn" }, icon + "<span></span>");
      b.querySelector("span").textContent = cfg.label;
      var grp = el("div", { class: "btn-group" });
      grp.appendChild(b);
      bar.appendChild(grp);
      b.addEventListener("click", open);
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", addButton);
  else addButton();
})();

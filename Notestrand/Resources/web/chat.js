/* The transcript: Swift calls LH.render(state) and LH.stream(text); cards post answers back. */
(function () {
  "use strict";

  var md = window.markdownit({ html: false, linkify: true, breaks: false })
    .use(window.texmath, { engine: window.katex, delimiters: ["dollars", "brackets"], katexOptions: { throwOnError: false } });
  // Remote loads are blocked natively, so show images as links instead of broken boxes.
  // ```mermaid fences become diagrams once the message is complete (drawDiagrams); until then they read as code.
  // ```demo fences become sandboxed live pages the same way.
  var MERMAID_START = /^\s*(?:(?:graph|flowchart)\s+(?:TD|TB|BT|LR|RL)\b|(?:sequenceDiagram|classDiagram|stateDiagram(?:-v2)?|erDiagram|gantt|pie|mindmap|timeline)\b)/;
  var defaultFence = md.renderer.rules.fence;
  md.renderer.rules.fence = function (tokens, idx, options, env, self) {
    var t = tokens[idx], lang = t.info.trim().toLowerCase();
    // A complete HTML page in a reply is meant to be seen, so it runs as a demo too (same sandbox).
    var page = (lang === "html" || !lang) && /^\s*(<!doctype html|<html[\s>])/i.test(t.content);
    var kind = lang === "mermaid" || (!lang && MERMAID_START.test(t.content)) ? "mermaid-block"
      : lang === "demo" || page ? "demo-block" : lang === "chart" ? "chart-block" : null;
    if (!kind) return defaultFence(tokens, idx, options, env, self);
    var src = md.utils.escapeHtml(t.content);
    return '<div class="' + kind + '" data-src="' + src + '"><pre class="mermaid-src"><code>' + src + "</code></pre></div>";
  };
  md.renderer.rules.image = function (tokens, idx) {
    var t = tokens[idx], src = md.utils.escapeHtml(t.attrGet("src") || "");
    return '<a href="' + src + '">' + md.utils.escapeHtml(t.content || "image") + "</a>";
  };

  var dark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;

  // Mermaid is ~3 MB of script, most chats never draw a diagram, and parsing it held up every page load.
  // It loads on first need (or shortly after the page is idle), and anything waiting for it runs once it's in.
  var mermaidWaiting = null;
  function withMermaid(fn) {
    if (window.mermaid) return fn();
    if (mermaidWaiting) return mermaidWaiting.push(fn);
    mermaidWaiting = [fn];
    var s = document.createElement("script");
    s.src = "vendor/mermaid.min.js";
    s.onload = function () {
      window.mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: dark ? "dark" : "default", flowchart: { htmlLabels: false } });
      mermaidWaiting.splice(0).forEach(function (f) { f(); });
    };
    s.onerror = function () { mermaidWaiting = null; }; // diagrams keep showing their source
    document.head.appendChild(s);
  }
  setTimeout(function () { withMermaid(function () {}); }, 1200);

  var log = document.getElementById("log");
  var blocks = {}; // key -> { sig, el }
  var streamEl = null;
  var mermaidSeq = 0;

  function post(msg) { window.webkit.messageHandlers.lh.postMessage(msg); }
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  function render(text) { return md.render(String(text || "")); }
  function inline(text) { return md.renderInline(String(text || "")); }
  function el(tag, cls, html) { var e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; }
  function parse(s) { try { return JSON.parse(s || "{}"); } catch (e) { return {}; } }
  function nearBottom() { return window.innerHeight + window.scrollY >= document.body.scrollHeight - 120; }
  function toBottom() { window.scrollTo(0, document.body.scrollHeight); }

  // Same options order on every render: seeded by the call id.
  function shuffled(arr, seed) {
    var h = 2166136261;
    for (var i = 0; i < seed.length; i++) { h ^= seed.charCodeAt(i); h = Math.imul(h, 16777619); }
    var a = arr.slice();
    for (var j = a.length - 1; j > 0; j--) {
      h = Math.imul(h ^ (h >>> 15), 2246822507) >>> 0;
      var k = h % (j + 1), t = a[j]; a[j] = a[k]; a[k] = t;
    }
    return a;
  }

  function options(args) {
    var raw = args.options;
    if (typeof raw === "string") { try { raw = JSON.parse(raw); } catch (e) { raw = []; } }
    return (Array.isArray(raw) ? raw : []).map(function (o, i) {
      return { label: o.label, value: o.value || o.label, index: i + 1 };
    });
  }

  function correctValues(args, opts) {
    var raw = Array.isArray(args.correctAnswer) ? args.correctAnswer : [args.correctAnswer];
    return raw.map(function (v) { var o = opts.filter(function (x) { return x.label === v; })[0]; return o ? o.value : v; });
  }

  // ---------- blocks ----------

  function userBlock(m) {
    if (m.toolName === "handoff") return el("div", "divider", "Assessment done · planning your lesson");
    var thinking = m.text.indexOf("*Your thinking*") === 0;
    var e = el("div", "msg user" + (thinking ? " thinking" : ""));
    var att = "";
    (m.images || []).forEach(function (b64) { att += '<img class="att-img" alt="Attached photo" src="data:image/jpeg;base64,' + b64 + '">'; });
    (m.documents || []).forEach(function (d) { att += '<span class="att-doc">📄 ' + esc(d.name) + "</span>"; });
    e.innerHTML = (att ? '<div class="atts">' + att + "</div>" : "") +
      (thinking ? '<div class="lh-label">Your thinking</div>' + render(m.text.replace("*Your thinking*", "")) : render(m.text));
    return e;
  }

  // Models often write A[Profit (π)] or -->|CM = £15|, which Mermaid rejects unless the label is quoted.
  function quoteLabels(src) {
    return src
      .replace(/([A-Za-z0-9_-]+)\[(?!["\[(\/\\])([^\]\n]*?)\](?!\])/g, function (_, id, label) {
        return id + '["' + label.replace(/"/g, "#quot;") + '"]';
      })
      .replace(/(-->|---|==>|-\.->|--x|--o)\s*\|(?!")([^|\n]+?)\|/g, function (_, arrow, label) {
        return arrow + '|"' + label.replace(/"/g, "#quot;") + '"|';
      });
  }

  // Other common slips: an edge left dangling at the end of a line, and subgraph "Title" without an id.
  function repairMermaid(src) {
    var n = 0;
    return quoteLabels(src)
      .replace(/\s*-->\s*\|[^|\n]*\|\s*$/gm, "")
      .replace(/^(\s*)subgraph\s+"([^"\n]*)"\s*$/gm, function (_, indent, title) { return indent + "subgraph sg" + (++n) + ' ["' + title + '"]'; });
  }

  /// Draws Mermaid source into box; returns false (leaving box alone) when it can't be parsed even after repairs.
  function drawMermaid(box, src) {
    var candidates = [src, quoteLabels(src), repairMermaid(src)];
    for (var i = 0; i < candidates.length; i++) {
      try {
        window.mermaid.parse(candidates[i]); // throws on a syntax error
        window.mermaid.mermaidAPI.render("m" + (++mermaidSeq), candidates[i], function (svg) { box.innerHTML = svg; });
        return true;
      } catch (e) {}
    }
    return false;
  }

  // Runs inside each demo: base styles, and reports its height so the frame fits its content.
  // flow-root keeps the first and last child's margins inside the body, or the measured height misses them and the frame clips its last line.
  var DEMO_HEAD = '<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<style>:root{color-scheme:light dark}html,body{margin:0;font:16px -apple-system,system-ui,sans-serif;background:transparent}body{display:flow-root}</style>' +
    '<script>addEventListener("error",function(e){var d=document.createElement("pre");d.style.cssText="color:#c43c32;white-space:pre-wrap;font:13px ui-monospace,Menlo,monospace;margin:8px";' +
    'd.textContent="This demo hit an error: "+e.message;(document.body||document.documentElement).appendChild(d)});<\/script>' +
    '<script>(function(){function s(){var b=document.body;if(b)parent.postMessage({lhDemoHeight:Math.ceil(b.getBoundingClientRect().height)+2},"*")}' +
    'addEventListener("load",function(){s();if(window.ResizeObserver)new ResizeObserver(s).observe(document.body)});setTimeout(s,400)})()<\/script>';

  // Chart.js is the one library demos may use; any <script src="...chart..."> gets the bundled copy, since frames can't load files.
  var CHART_TAG = function () { return "<script>" + window.LH_CHART_SRC + "<\/script>"; };
  function withChartJS(src) {
    return src.replace(/<script\b[^>]*\bsrc\s*=\s*["'][^"']*chart[^"']*["'][^>]*>\s*<\/script>/gi, CHART_TAG);
  }

  function drawDemo(box, src, docOverride) {
    var page = withChartJS(src);
    var at = page.search(/<head[^>]*>/i);
    var doc = docOverride || (at < 0 ? DEMO_HEAD + page : page.replace(/<head[^>]*>/i, function (h) { return h + DEMO_HEAD; }));
    var frame = document.createElement("iframe");
    // Scripts only: an opaque origin with no access to the app, the transcript, storage, popups or navigation.
    // The app's content blocker also stops any network request from inside it.
    frame.setAttribute("sandbox", "allow-scripts");
    frame.setAttribute("title", "Interactive demo");
    frame.className = "demo-frame";
    frame.srcdoc = doc;
    var code = el("details", "demo-code");
    code.appendChild(el("summary", null, "Source"));
    code.appendChild(el("pre", "mermaid-src", "<code>" + esc(src) + "</code>"));
    box.innerHTML = "";
    box.appendChild(frame);
    box.appendChild(code);
  }

  /* Runs inside the sandboxed frame: draws a ```chart spec with Chart.js, sliders and readouts. Must be self-contained. */
  function renderChart(spec) {
    var dark = window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches;
    var fg = dark ? "#e5e5ea" : "#1d1d1f", grid = dark ? "rgba(255,255,255,.12)" : "rgba(0,0,0,.08)";
    var palette = ["#2f6fed", "#e8710a", "#1f8a4c", "#c43c32", "#7c4dff", "#0f8b8d", "#b8860b"];
    var env = {};
    function esc(t) { return String(t).replace(/[&<>]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]; }); }
    function compile(expr) {
      if (typeof expr === "number") return function () { return expr; };
      // ^ in a chart formula means a power, never XOR.
      var code = String(expr).replace(/\^/g, "**");
      var f = new Function("x", "env", "with (Math) { with (env) { return (" + code + "); } }");
      return function (x) { var v = f(x, env); return typeof v === "number" && isFinite(v) ? v : null; };
    }
    function fmt(v) { return v == null ? "—" : Number(v).toLocaleString(undefined, { maximumFractionDigits: 2 }); }
    document.body.innerHTML = (spec.title ? '<div style="font-weight:600;margin:6px 6px 4px">' + esc(spec.title) + "</div>" : "") +
      '<div style="position:relative;height:300px;margin:0 4px"><canvas id="lh-c"></canvas></div><div id="lh-ctl" style="margin:8px 6px"></div><div id="lh-ro" style="margin:4px 6px 8px;font-weight:600"></div>';
    var ctl = document.getElementById("lh-ctl"), ro = document.getElementById("lh-ro");
    (spec.sliders || []).forEach(function (sl) {
      env[sl.name] = sl.value != null ? sl.value : sl.min;
      var row = document.createElement("label");
      row.style.cssText = "display:block;margin:6px 0;font-size:15px";
      row.innerHTML = esc(sl.label || sl.name) + ': <b></b><br><input type="range" style="width:100%;min-height:28px">';
      var input = row.querySelector("input"), out = row.querySelector("b");
      input.min = sl.min; input.max = sl.max; input.step = sl.step || (sl.max - sl.min) / 100; input.value = env[sl.name];
      out.textContent = fmt(env[sl.name]);
      input.setAttribute("aria-label", sl.label || sl.name);
      input.oninput = function () { env[sl.name] = +input.value; out.textContent = fmt(env[sl.name]); update(); };
      ctl.appendChild(row);
    });
    var X = spec.x || {}, Y = spec.y || {}, xmin = X.min != null ? X.min : 0, xmax = X.max != null ? X.max : 10;
    var lines = (spec.lines || []).map(function (l) { return { spec: l, f: l.fn != null ? compile(l.fn) : null }; });
    var points = (spec.points || []).map(function (p) { return { spec: p, fx: compile(p.x), fy: compile(p.y) }; });
    var readouts = (spec.readouts || []).map(function (r) { return { spec: r, f: compile(r.value) }; });
    function lineData(l) {
      if (l.spec.data) return l.spec.data.map(function (d) { return { x: d[0], y: d[1] }; });
      var out = [], n = 240;
      for (var i = 0; i <= n; i++) { var x = xmin + (xmax - xmin) * i / n; out.push({ x: x, y: l.f(x) }); }
      return out;
    }
    var chart, isBar = spec.type === "bar";
    if (isBar) {
      chart = new Chart(document.getElementById("lh-c"), {
        type: "bar",
        data: { labels: spec.categories || [], datasets: (spec.series || []).map(function (s, i) { return { label: s.label, data: s.values, backgroundColor: palette[i % palette.length] }; }) },
        options: { responsive: true, maintainAspectRatio: false, animation: false, color: fg,
          scales: { x: { ticks: { color: fg }, grid: { color: grid }, title: { display: !!X.label, text: X.label, color: fg } },
                    y: { ticks: { color: fg }, grid: { color: grid }, title: { display: !!Y.label, text: Y.label, color: fg }, min: Y.min, max: Y.max } } }
      });
      return;
    }
    var datasets = lines.map(function (l, i) {
      return { label: l.spec.label, data: lineData(l), showLine: true, pointRadius: l.spec.data ? 3 : 0, borderWidth: 2.5,
               borderColor: l.spec.color || palette[i % palette.length], backgroundColor: l.spec.color || palette[i % palette.length],
               borderDash: l.spec.dashed ? [6, 5] : [], tension: 0 };
    });
    var shade = spec.shade && spec.shade.between;
    if (shade) {
      var a = lines.findIndex(function (l) { return l.spec.label === shade[0]; }), b = lines.findIndex(function (l) { return l.spec.label === shade[1]; });
      if (a >= 0 && b >= 0) datasets[a].fill = { target: b, above: "rgba(31,138,76,.18)", below: "rgba(196,60,50,.15)" };
    }
    var pointBase = datasets.length;
    points.forEach(function (p, i) {
      datasets.push({ label: p.spec.label, data: [], pointRadius: 7, pointHoverRadius: 9, showLine: false,
                      backgroundColor: p.spec.color || "#e0a000", borderColor: fg, borderWidth: 1.5 });
    });
    chart = new Chart(document.getElementById("lh-c"), {
      type: "scatter",
      data: { datasets: datasets },
      options: { responsive: true, maintainAspectRatio: false, animation: false, color: fg,
        plugins: { legend: { labels: { color: fg, usePointStyle: true } },
                   tooltip: { callbacks: { label: function (c) { return (c.dataset.label ? c.dataset.label + ": " : "") + "(" + fmt(c.parsed.x) + ", " + fmt(c.parsed.y) + ")"; } } } },
        scales: { x: { type: "linear", min: xmin, max: xmax, ticks: { color: fg }, grid: { color: grid }, title: { display: !!X.label, text: X.label, color: fg } },
                  y: { min: Y.min, max: Y.max, ticks: { color: fg }, grid: { color: grid }, title: { display: !!Y.label, text: Y.label, color: fg } } } }
    });
    function update() {
      lines.forEach(function (l, i) { if (!l.spec.data) chart.data.datasets[i].data = lineData(l); });
      points.forEach(function (p, i) {
        var x = p.fx(0), y = p.fy(x == null ? 0 : x);
        chart.data.datasets[pointBase + i].data = x == null || y == null ? [] : [{ x: x, y: y }];
      });
      chart.update("none");
      ro.innerHTML = readouts.map(function (r) { return esc(r.spec.label) + ": " + fmt(r.f(0)) + (r.spec.unit ? " " + esc(r.spec.unit) : ""); }).join("<br>");
    }
    update();
  }

  function drawChart(box, src) {
    var spec;
    try { spec = JSON.parse(src); } catch (e) {
      box.insertAdjacentHTML("beforeend", '<div class="note">This chart\'s data couldn\'t be read: ' + esc(e.message) + "</div>");
      return;
    }
    var doc = DEMO_HEAD + "<body></body>" + CHART_TAG() + "<script>(" + renderChart.toString() + ")(" + JSON.stringify(spec).replace(/</g, "\\u003c") + ");<\/script>";
    drawDemo(box, src, doc);
  }

  function drawDiagrams(root) {
    Array.prototype.forEach.call(root.querySelectorAll(".mermaid-block"), function (box) {
      withMermaid(function () { drawMermaid(box, box.getAttribute("data-src")); });
    });
    Array.prototype.forEach.call(root.querySelectorAll(".demo-block"), function (box) { drawDemo(box, box.getAttribute("data-src")); });
    Array.prototype.forEach.call(root.querySelectorAll(".chart-block"), function (box) { drawChart(box, box.getAttribute("data-src")); });
    return root;
  }

  window.addEventListener("message", function (e) {
    var h = e.data && e.data.lhDemoHeight;
    if (typeof h !== "number") return;
    Array.prototype.forEach.call(document.querySelectorAll("iframe.demo-frame"), function (f) {
      if (f.contentWindow === e.source) f.style.height = Math.min(Math.max(h, 120), 900) + "px";
    });
  });

  function assistantText(text) { return drawDiagrams(el("div", "msg assistant", render(text))); }

  function chip(call, result) {
    var a = parse(call.arguments), label;
    switch (call.name) {
      case "vault_search": label = "Searched your vault for “" + esc(a.query) + "”"; break;
      case "vault_read": label = "Read " + esc(a.path); break;
      case "web_search": label = "Searched the web for “" + esc(a.query) + "”"; break;
      case "web_fetch": label = "Opened " + esc(String(a.url || "").replace(/^https?:\/\//, "").split("/")[0]); break;
      case "vault_write": label = (a.append ? "Added to " : "Saved ") + "Notestrand/" + esc(a.path); break;
      case "list_sessions": label = "Looked at your knowledge map"; break;
      case "list_propositions": label = "Read what you learned in “" + esc(a.session) + "”"; break;
      case "probe_done": label = "Assessment"; break;
      default: label = esc(call.name);
    }
    if (result && result.isError) label += " · failed: " + esc(String(result.text).split("\n")[0].slice(0, 80));
    var e = el("div", "chip" + (result && result.isError ? " failed" : ""), label);
    if (result && result.isError) e.title = result.text;
    return e;
  }

  function assessment(call) {
    var a = parse(call.arguments).assessment || {};
    var e = el("section", "card assessment");
    e.appendChild(el("h3", null, "Where you are"));
    (a.strands || []).forEach(function (s) {
      var row = el("div", "strand");
      row.appendChild(el("div", "strand-name", inline(s.strand)));
      row.appendChild(el("div", "strand-body", render(s.assessment)));
      e.appendChild(row);
    });
    if (a.summary) e.appendChild(el("div", "summary", render(a.summary)));
    return e;
  }

  function planBlock(src, current, visited) {
    var e = el("section", "card plan");
    e.appendChild(el("h3", null, "Lesson plan"));
    var box = el("div", "diagram");
    e.appendChild(box);
    var styled = src.replace(/^```(?:mermaid)?\s*|```\s*$/g, "");
    visited.forEach(function (n) { if (n !== current) styled += "\nstyle " + n + " stroke:#2e9d5b,stroke-width:2px"; });
    if (current) styled += "\nstyle " + current + " fill:#ffd54a,stroke:#b8860b,stroke-width:3px,color:#000";
    if (!window.mermaid) box.innerHTML = '<div class="diagram-wait">Drawing the plan…</div>';
    withMermaid(function () { if (!drawMermaid(box, styled)) box.innerHTML = '<pre class="mermaid-src">' + esc(src) + "</pre>"; });
    return e;
  }

  function problemBlock(call, concluded) {
    var a = parse(call.arguments);
    var e = el("section", "card problem");
    e.appendChild(el("div", "badge", "Problem · " + esc(a.mode || "")));
    e.appendChild(el("div", "body", render(a.statement)));
    if (concluded) {
      var c = parse(concluded.arguments);
      e.appendChild(el("div", "verdict " + esc(c.outcome), "<strong>" + esc(String(c.outcome || "").replace(/([A-Z])/g, " $1")) + "</strong>" + render(c.verdict)));
      var d = el("details", "solution");
      d.appendChild(el("summary", null, "Model solution"));
      d.appendChild(el("div", null, render(a.modelSolution)));
      e.appendChild(d);
    }
    return e;
  }

  function answeredCard(call, result) {
    var a = parse(call.arguments), ans = parse(result.text);
    var graded = call.name !== "ask_user_question";
    var opts = options(a), correct = graded ? correctValues(a, opts) : [];
    var chosen = (ans.answers || []).map(function (x) { return x.index; });
    var e = el("section", "card answered" + (graded ? (ans.correct ? " right" : " wrong") : ""));
    if (a.type) e.appendChild(el("div", "badge", a.type === "predict" ? "Prediction" : "Check"));
    e.appendChild(el("div", "question", render(a.question)));
    if (ans.dismissed) { e.appendChild(el("div", "note", "Skipped")); return e; }
    if (opts.length) {
      var ul = el("ul", "options done");
      shuffled(opts, call.id).forEach(function (o) {
        var isChosen = chosen.indexOf(o.index) >= 0, isCorrect = correct.indexOf(o.value) >= 0;
        var li = el("li", (isChosen ? "chosen " : "") + (isCorrect ? "correct" : ""));
        li.innerHTML = '<span class="mark" aria-hidden="true">' + (isCorrect ? "✓" : isChosen ? "✗" : "") + "</span>" + inline(o.label) +
          (isChosen ? '<span class="sr"> (your answer)</span>' : "") + (isCorrect ? '<span class="sr"> (correct)</span>' : "");
        ul.appendChild(li);
      });
      e.appendChild(ul);
    }
    var meta = [];
    if (ans.dontKnow) meta.push("You said you don't know");
    if (ans.confidence != null) meta.push(ans.confidence + "% sure");
    if (meta.length) e.appendChild(el("div", "note", esc(meta.join(" · "))));
    if (ans.other) e.appendChild(el("div", "note", "Other: " + inline(ans.other)));
    if (ans.text) e.appendChild(el("blockquote", null, render(ans.text)));
    if (ans.thinking) e.appendChild(el("blockquote", "thinking", '<div class="lh-label">Your thinking</div>' + render(ans.thinking)));
    if (ans.thinkingWhileReading) e.appendChild(el("blockquote", "thinking", '<div class="lh-label">While reading</div>' + render(ans.thinkingWhileReading)));
    if (graded && a.explanation) e.appendChild(el("div", "explanation", render(a.explanation)));
    return e;
  }

  function activeCard(call) {
    var a = parse(call.arguments);
    var graded = call.name !== "ask_user_question";
    var multi = a.multiSelect === true;
    var opts = shuffled(options(a), call.id);
    var state = { values: [], dontKnow: false, confidence: 70 };
    var e = el("section", "card active");
    e.setAttribute("aria-label", "Question");
    if (a.type) e.appendChild(el("div", "badge", a.type === "predict" ? "Prediction: what do you expect?" : "Check"));
    e.appendChild(el("div", "question", render(a.question)));
    if (a.details) e.appendChild(el("div", "details", render(a.details)));

    var submit = el("button", "submit", "Submit");
    var conf, other, text;
    function refresh() {
      Array.prototype.forEach.call(e.querySelectorAll(".options button"), function (b) {
        var on = state.values.indexOf(b.dataset.value) >= 0;
        b.classList.toggle("selected", on);
        b.setAttribute("aria-pressed", on ? "true" : "false");
      });
      if (idk) { idk.classList.toggle("selected", state.dontKnow); idk.setAttribute("aria-pressed", state.dontKnow ? "true" : "false"); }
      if (conf) conf.style.display = graded && !state.dontKnow ? "" : "none";
      var hasText = (other && other.value.trim()) || (text && text.value.trim());
      submit.disabled = !(state.values.length || state.dontKnow || hasText);
    }

    if (opts.length) {
      var ul = el("div", "options");
      ul.setAttribute("role", "group");
      opts.forEach(function (o) {
        var b = el("button", "option", inline(o.label));
        b.type = "button";
        b.dataset.value = o.value;
        b.onclick = function () {
          state.dontKnow = false;
          var i = state.values.indexOf(o.value);
          if (multi) { if (i >= 0) state.values.splice(i, 1); else state.values.push(o.value); }
          else state.values = i >= 0 ? [] : [o.value];
          refresh();
        };
        ul.appendChild(b);
      });
      e.appendChild(ul);
    }
    var idk = null;
    if (graded) {
      idk = el("button", "option idk", "I don't know");
      idk.type = "button";
      idk.onclick = function () { state.dontKnow = !state.dontKnow; if (state.dontKnow) state.values = []; refresh(); };
      e.appendChild(idk);
      conf = el("label", "confidence");
      conf.innerHTML = '<span>How sure are you? <b>70%</b></span><input type="range" min="0" max="100" step="5" value="70">';
      var range = conf.querySelector("input");
      range.oninput = function () { state.confidence = +range.value; conf.querySelector("b").textContent = range.value + "%"; };
      e.appendChild(conf);
    } else if (opts.length) {
      other = el("input", "other");
      other.placeholder = "Other…";
      other.setAttribute("aria-label", "Other answer");
      other.oninput = refresh;
      e.appendChild(other);
    } else {
      text = el("textarea", "answer");
      text.placeholder = "Your answer";
      text.setAttribute("aria-label", "Your answer");
      text.oninput = refresh;
      e.appendChild(text);
    }
    var thinking = el("textarea", "thinking-input");
    thinking.placeholder = graded ? "Think out loud (optional): why this answer? What are you unsure about?" : "Anything to add? (optional)";
    thinking.setAttribute("aria-label", "Your thinking");
    e.appendChild(thinking);
    var reading = null;
    if (a.type === "check") {
      reading = el("textarea", "thinking-input");
      reading.placeholder = "Thoughts while reading the explanation (optional)";
      reading.setAttribute("aria-label", "Thoughts while reading");
      e.appendChild(reading);
    }
    submit.type = "button";
    submit.onclick = function () {
      submit.disabled = true;
      post({ type: "answer", answer: {
        callId: call.id, values: state.values, dontKnow: state.dontKnow,
        confidence: graded && !state.dontKnow && state.values.length ? state.confidence : null,
        other: other ? other.value : null, text: text ? text.value : null,
        thinking: thinking.value, readingThinking: reading ? reading.value : null
      } });
    };
    var row = el("div", "actions");
    var skip = el("button", "skip", "Skip");
    skip.type = "button";
    skip.onclick = function () { post({ type: "answer", answer: { callId: call.id, dismissed: true } }); };
    row.appendChild(skip);
    row.appendChild(submit);
    e.appendChild(row);
    refresh();
    return e;
  }

  // The app icon's N as one strand: a highlight runs along it while the model thinks.
  // The app icon's N with colour flowing along it end to end while the model thinks.
  var N_D = "M6 19V8.5Q6 4.6 9.4 6.3L15.6 17.2Q18 20.4 18 16.5V5";
  var REDUCED = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;
  var THINKING = '<span class="n-thinking" role="status"><svg viewBox="0 0 24 24" aria-hidden="true">' +
    '<path class="base" d="' + N_D + '" pathLength="100"/>' +
    (REDUCED ? "" : '<path class="run" d="' + N_D + '" pathLength="100">' +
      '<animate attributeName="stroke-dashoffset" from="140" to="0" dur="1.8s" repeatCount="indefinite"/></path>') +
    '</svg><span class="thinking-label">Thinking…</span></span>';

  // Only show reasoning lines that read as prose; drafts of JSON, LaTeX or code are skipped.
  function readableThought(text) {
    var lines = String(text || "").split(/\n+/).map(function (l) { return l.replace(/[*_#`>]/g, "").trim(); });
    for (var i = lines.length - 1; i >= 0; i--) {
      var l = lines[i], letters = (l.match(/[A-Za-z]/g) || []).length;
      if (l.length < 12 || /[{}\[\]\\$<=|]|":|\b(function|var|const)\b/.test(l) || letters / l.length < 0.6) continue;
      return l.length > 90 ? l.slice(0, l.lastIndexOf(" ", 88)) + "…" : l;
    }
    return null;
  }

  // One clock for every indicator, so a new one (after a tool call) continues the motion instead of restarting it.
  var THINK_T0 = performance.now();
  function syncThinking(root) {
    var t = (performance.now() - THINK_T0) / 1000;
    var svg = root.querySelector(".n-thinking svg");
    if (svg && svg.setCurrentTime) svg.setCurrentTime(t);
    // The shimmer is CSS; a negative delay starts a new label mid-sweep instead of restarting it.
    var label = root.querySelector(".thinking-label");
    if (label) label.style.animationDelay = -t + "s";
  }

  // ---------- message action bars ----------

  var ICONS = {
    copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',
    speak: '<path d="M11 5 6 9H3v6h3l5 4V5z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/>',
    retry: '<path d="M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5"/>',
    edit: '<path d="M4 20h4L19 9l-4-4L4 16v4z"/>',
    branch: '<circle cx="6" cy="5" r="2"/><circle cx="6" cy="19" r="2"/><circle cx="18" cy="8" r="2"/><path d="M6 7v10M18 10c0 4-6 3-11 7"/>'
  };

  // Swift encodes Date as seconds since 1 Jan 2001.
  function msgDate(m) { return typeof m.created === "number" ? new Date((m.created + 978307200) * 1000) : null; }
  function ago(d) {
    var s = (Date.now() - d.getTime()) / 1000;
    if (s < 60) return "just now";
    if (s < 3600) return Math.floor(s / 60) + (s < 120 ? " minute ago" : " minutes ago");
    if (s < 86400) return Math.floor(s / 3600) + (s < 7200 ? " hour ago" : " hours ago");
    return d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });
  }

  function speedLabel(tps) {
    var s = el("span", "speed", (tps >= 10 ? Math.round(tps) : tps.toFixed(1)) + " tok/s");
    s.setAttribute("aria-label", "Generated at " + Math.round(tps) + " tokens per second");
    return s;
  }

  function actionBar(align, items, date) {
    var bar = el("div", "actions " + align);
    var time = date ? el("button", "time", esc(ago(date))) : null;
    if (time) {
      time.setAttribute("aria-label", "Sent " + date.toLocaleString());
      var full = false;
      // Tap swaps between "3 hours ago" and the exact time (no hover tooltips on touch).
      time.onclick = function () { full = !full; time.textContent = full ? date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : ago(date); };
    }
    if (time && align === "right") bar.appendChild(time);
    items.forEach(function (it) {
      var b = el("button", "act" + (it.on ? " on" : ""), '<svg viewBox="0 0 24 24" aria-hidden="true">' + ICONS[it.icon] + "</svg>");
      b.setAttribute("aria-label", it.label);
      if (it.on) b.setAttribute("aria-pressed", "true");
      b.onclick = function () {
        post(it.msg);
        if (it.icon === "copy") { b.classList.add("done"); setTimeout(function () { b.classList.remove("done"); }, 1200); }
      };
      bar.appendChild(b);
    });
    if (time && align !== "right") bar.appendChild(time);
    return bar;
  }

  // ---------- render ----------

  function build(state) {
    var msgs = state.messages || [], out = [];
    var results = {}, concludes = [], quizNodes = [];
    msgs.forEach(function (m) { if (m.role === "tool") results[m.toolCallId] = m; });
    msgs.forEach(function (m) {
      (m.toolCalls || []).forEach(function (c) {
        var r = results[c.id];
        if (c.name === "conclude" && r && !r.isError) concludes.push(c);
        if (c.name === "quiz" && !(r && r.isError)) { var n = parse(c.arguments).nodeId; if (n) quizNodes.push(n); }
      });
    });
    var current = quizNodes[quizNodes.length - 1] || null;
    // A problem is concluded by the first successful conclude after it.
    var problemOrder = [];
    msgs.forEach(function (m) { (m.toolCalls || []).forEach(function (c) { if (c.name === "problem" || c.name === "conclude") problemOrder.push(c); }); });
    function conclusionOf(call) {
      var i = problemOrder.indexOf(call);
      for (var j = i + 1; j < problemOrder.length; j++) {
        if (problemOrder[j].name === "problem") return null;
        if (concludes.indexOf(problemOrder[j]) >= 0) return problemOrder[j];
      }
      return null;
    }

    // The learner's last input (a typed message or a card answer) is where regenerate/edit rewind to.
    function isInput(m) { return (m.role === "user" && !m.toolName) || !!m.answer; }
    var lastInput = -1;
    msgs.forEach(function (m, i) { if (isInput(m)) lastInput = i; });
    // A turn's action bar goes under its last assistant message with text; copy/speak cover the whole turn.
    var turnText = {}, turnEnd = {}, turnSpeed = {}, turnStart = 0;
    msgs.forEach(function (m, i) {
      if (m.role === "user" && !m.toolName) turnStart = i;
      if (m.role === "assistant" && m.speed) turnSpeed[turnStart] = m.speed;
      if (m.role === "assistant" && m.text) {
        turnText[turnStart] = (turnText[turnStart] ? turnText[turnStart] + "\n\n" : "") + m.text;
        turnEnd[turnStart] = i;
      }
    });
    turnStart = 0;

    msgs.forEach(function (m, idx) {
      if (m.role === "user") {
        out.push({ key: m.id, sig: m.text + (m.images || []).length + (m.documents || []).length, make: function () { return userBlock(m); } });
        if (m.toolName) return;
        turnStart = idx;
        var last = idx === lastInput, d = msgDate(m), text = m.text.replace("*Your thinking*\n\n", "");
        var items = [{ icon: "copy", label: "Copy message", msg: { type: "copy", text: text } }];
        if (last) items.unshift({ icon: "retry", label: "Send again", msg: { type: "regenerate" } }, { icon: "edit", label: "Edit message", msg: { type: "edit" } });
        // Earlier messages: redo from here in a copy of the chat, keeping the original.
        else items.unshift({ icon: "branch", label: "Edit in a new branch", msg: { type: "branch", id: m.id } });
        out.push({ key: m.id + ":bar", sig: String(last) + (d ? ago(d) : ""), make: function () { return actionBar("right", items, d); } });
        return;
      }
      if (m.role !== "assistant") return;
      if (m.text) out.push({ key: m.id + ":t", sig: m.text, make: function () { return assistantText(m.text); } });
      var start = turnStart;
      (m.toolCalls || []).forEach(function (c) {
        var r = results[c.id];
        if (c.name === "probe" || c.name === "quiz" || c.name === "ask_user_question") {
          if (r && !r.isError) out.push({ key: c.id, sig: "done" + r.text, make: function () { return answeredCard(c, r); } });
          else if (!r && state.pending.indexOf(c.id) >= 0) out.push({ key: c.id, sig: "pending", make: function () { return activeCard(c); } });
        } else if (c.name === "plan_init") {
          if (r && !r.isError) {
            var src = parse(c.arguments).mermaid || "";
            out.push({ key: c.id, sig: src + "|" + current + "|" + quizNodes.join(","), make: function () { return planBlock(src, current, quizNodes); } });
          }
        } else if (c.name === "problem") {
          if (r && !r.isError) {
            var done = conclusionOf(c);
            out.push({ key: c.id, sig: done ? "done" : "open", make: function () { return problemBlock(c, done); } });
          }
        } else if (c.name === "probe_done") {
          if (r && !r.isError) out.push({ key: c.id, sig: c.arguments, make: function () { return assessment(c); } });
        } else if (c.name !== "conclude") {
          out.push({ key: c.id, sig: (r ? (r.isError ? "err" : "ok") : "run") + c.arguments, make: function () { return chip(c, r); } });
        }
      });
      if (turnEnd[start] === idx && !state.running) {
        var text = turnText[start], d = msgDate(m), latest = idx > lastInput;
        var items = [
          { icon: "copy", label: "Copy reply", msg: { type: "copy", text: text } },
          { icon: "speak", label: "Read aloud", msg: { type: "speak", text: text } }
        ];
        if (latest) items.push({ icon: "retry", label: "Regenerate reply", msg: { type: "regenerate" } });
        var speed = turnSpeed[start];
        out.push({ key: m.id + ":bar", sig: [latest, d ? ago(d) : "", text.length, speed].join("|"), make: function () {
          var bar = actionBar("left", items, d);
          if (speed) bar.appendChild(speedLabel(speed));
          return bar;
        } });
      }
    });
    return out;
  }

  var currentSession = null, streamStart = null;

  window.LH = {
    /// Settings: transcript text size (pt) and accent colour (#rrggbb).
    style: function (size, accent, showSpeed) {
      document.documentElement.classList.toggle("hide-speed", showSpeed === false);
      var root = document.documentElement.style;
      root.setProperty("--text-size", size + "px");
      root.setProperty("--accent", accent);
      var v = parseInt(accent.slice(1), 16);
      root.setProperty("--accent-soft", "rgba(" + (v >> 16 & 255) + "," + (v >> 8 & 255) + "," + (v & 255) + ",0.14)");
    },
    /// Used by the unit tests: whether Mermaid source can be drawn (after repairs).
    canDraw: function (src) { return drawMermaid(document.createElement("div"), src); },
    /// Used by the unit tests: start loading Mermaid now (canDraw needs it loaded).
    loadMermaid: function () { withMermaid(function () {}); },
    /// Used by the unit tests: the function that runs inside chart frames.
    chartRenderer: function () { return renderChart; },
    render: function (state) {
      var stick = nearBottom();
      if (state.id !== currentSession) { currentSession = state.id; blocks = {}; log.innerHTML = ""; streamEl = null; stick = true; }
      var list = build(state), seen = {}, prev = null;
      list.forEach(function (b) {
        seen[b.key] = true;
        var cur = blocks[b.key];
        if (!cur || cur.sig !== b.sig) {
          var made = b.make();
          if (cur) log.replaceChild(made, cur.el);
          cur = blocks[b.key] = { sig: b.sig, el: made };
        }
        var want = prev ? prev.nextSibling : log.firstChild;
        if (want !== cur.el) log.insertBefore(cur.el, want);
        prev = cur.el;
      });
      Object.keys(blocks).forEach(function (k) { if (!seen[k]) { blocks[k].el.remove(); delete blocks[k]; } });
      if (streamEl) log.appendChild(streamEl);
      if (!list.length && !streamEl) log.innerHTML = "";
      if (stick) toBottom();
    },
    stream: function (text, thinking) {
      var stick = nearBottom();
      if (text == null) { if (streamEl) { streamEl.remove(); streamEl = null; } streamStart = null; return; }
      if (!streamEl) { streamEl = el("div", "msg assistant streaming"); log.appendChild(streamEl); }
      if (text) {
        streamEl.innerHTML = render(text);
        // Live estimate (about 4 characters a token); the exact figure replaces it when the reply ends.
        var now = Date.now();
        if (!streamStart) streamStart = { t: now, len: text.length };
        var secs = (now - streamStart.t) / 1000;
        if (secs >= 1) streamEl.appendChild(speedLabel((text.length - streamStart.len) / 4 / secs));
      }
      else {
        // Keep the running animation; only swap the label as reasoning streams in.
        if (!streamEl.querySelector(".n-thinking")) { streamEl.innerHTML = THINKING; syncThinking(streamEl); }
        // Keep the last readable line rather than flicking back to "Thinking…" while code is being drafted.
        var line = readableThought(thinking), label = streamEl.querySelector(".thinking-label");
        if (line && label.textContent !== line) label.textContent = line;
      }
      if (stick) toBottom();
    }
  };
})();

// With ?log in the URL: a log panel on the left that keeps appending and
// scrolling, as a CI job page does, and links that keep the query.
(function () {
  if (!/(^|&)log(&|=|$)/.test(location.search.slice(1))) return;
  for (const a of document.querySelectorAll("a[href]")) a.href += location.search;
  const p = document.createElement("pre");
  p.style.cssText = "position:fixed;left:0;top:0;width:35vw;height:100vh;margin:0;overflow:auto;" +
    "background:#fff;color:#222;font:12px monospace";
  document.body.appendChild(p);
  let n = 0;
  setInterval(function () {
    for (let i = 0; i < 5; i++) {
      const s = document.createElement("span");
      s.textContent = new Date().toISOString() + " step " + n + ": " + "x".repeat(20 + (Math.random() * 100 | 0)) + "\n";
      if (n++ % 7 === 0) s.style.color = "#c00";
      p.appendChild(s);
    }
    while (p.childNodes.length > 4000) p.firstChild.remove();
    p.scrollTop = p.scrollHeight;
  }, 40);
})();

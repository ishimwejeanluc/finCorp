import { mkdirSync, writeFileSync } from "node:fs";

mkdirSync("dist", { recursive: true });
writeFileSync(
  "dist/index.html",
  `<!doctype html>
<html lang="en">
  <head><meta charset="utf-8"><title>ShopNow</title></head>
  <body>
    <h1>ShopNow</h1>
    <ul id="products"></ul>
    <script>
      fetch('/api/products')
        .then(r => r.json())
        .then(j => {
          const ul = document.getElementById('products');
          (j.data || []).forEach(p => {
            const li = document.createElement('li');
            li.textContent = p.name + ' — $' + p.price;
            ul.appendChild(li);
          });
        });
    </script>
  </body>
</html>`
);
console.log("built dist/index.html");

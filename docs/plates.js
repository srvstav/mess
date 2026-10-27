// A real plate photo for a meal, cut out with no background (docs/food/, credits in credits.html).
// Picked by the dishes on the menu, so a menu change in MySQL still finds the right plate.
(() => {
  // Keyword → photo. First match wins, so the main dish of each meal comes first.
  const PLATES = [
    [/paratha/i, "b1"],
    [/pancake/i, "b2"],
    [/rajma/i, "l1"],
    [/chole|bhature/i, "l2"],
    [/samosa/i, "h1"],
    [/tart|pastry|cake/i, "h2"],
    [/pizza|burger/i, "d1"],
    [/baati|churma/i, "d2"],
  ];

  const plateFor = dishes => {
    for (const [re, key] of PLATES) if (dishes.some(d => re.test(d))) return key;
    return "hero";
  };

  const PHOTOS_VERSION = 3;  // bump when a photo changes, so browsers fetch the new one

  const esc = s => s.replace(/[&<>"']/g, c => `&#${c.charCodeAt(0)};`);

  // small: the 200px file for little thumbnails. eager: for the first screen, skip lazy loading.
  window.plateHTML = (dishes, { small = false, eager = false, key = plateFor(dishes) } = {}) =>
    `<img class="plate-img" src="food/${key}${small ? "-sm" : ""}.webp?v=${PHOTOS_VERSION}" alt="${esc(dishes.join(", "))}"
      width="${small ? 200 : 720}" height="${small ? 200 : 720}" decoding="async"${eager ? "" : ' loading="lazy"'}>`;
})();

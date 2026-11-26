// Screenshot gallery: one large screenshot with a row of thumbnails, previous / next buttons, the
// arrow keys and swipe. Progressive enhancement: without JavaScript the page keeps the static layout
// (one large screenshot, three small ones below). No autoplay.
(() => {
  const section = document.querySelector(".shots");
  if (!section) return;
  const figures = Array.from(section.querySelectorAll("figure.shot"));
  const main = section.querySelector(".shot-main");
  if (!main || figures.length < 2) return;

  const mainImg = main.querySelector("img");
  const mainCaption = main.querySelector("figcaption");
  const slides = figures.map((figure) => {
    const img = figure.querySelector("img");
    return {
      src: img.getAttribute("src"),
      alt: img.getAttribute("alt"),
      width: img.getAttribute("width"),
      height: img.getAttribute("height"),
      caption: figure.querySelector("figcaption").textContent,
      label: figure.dataset.label || "",
    };
  });

  let current = 0;
  const thumbs = [];

  const controls = document.createElement("div");
  controls.className = "shot-controls";

  const arrow = (direction, label) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `shot-arrow shot-arrow-${direction}`;
    button.setAttribute("aria-label", label);
    // An SVG chevron centres exactly; a text glyph sits off-centre on its font baseline.
    const points = direction === "prev" ? "15 5 8 12 15 19" : "9 5 16 12 9 19";
    button.innerHTML = `<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false"><polyline points="${points}" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
    button.addEventListener("click", () => show(current + (direction === "prev" ? -1 : 1)));
    return button;
  };

  const list = document.createElement("div");
  list.className = "shot-thumbs";
  list.setAttribute("role", "group");
  list.setAttribute("aria-label", section.dataset.thumbsLabel || "Screenshots");

  slides.forEach((slide, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "shot-thumb";
    button.setAttribute("aria-label", slide.label || slide.caption);
    const img = document.createElement("img");
    img.src = slide.src;
    img.alt = "";
    img.loading = "lazy";
    img.width = 220;
    img.height = Math.round((220 * Number(slide.height)) / Number(slide.width)) || 146;
    button.append(img);
    if (slide.label) {
      const text = document.createElement("span");
      text.textContent = slide.label;
      button.append(text);
    }
    button.addEventListener("click", () => show(index));
    list.append(button);
    thumbs.push(button);
  });

  controls.append(arrow("prev", section.dataset.prevLabel || "Previous screenshot"), list,
    arrow("next", section.dataset.nextLabel || "Next screenshot"));
  main.after(controls);
  mainCaption.setAttribute("aria-live", "polite");
  section.classList.add("is-gallery");

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let switchToken = 0;

  // Fade and slide the large screenshot out, swap it once the next image is decoded, then bring it
  // back in from the other side. Rapid clicks cancel earlier switches (token), so the last one wins.
  async function show(index, animate = true) {
    const next = (index + slides.length) % slides.length;
    if (animate && next === current) return;
    const slide = slides[next];
    const forward = next > current || (current === slides.length - 1 && next === 0);
    const backward = current === 0 && next === slides.length - 1;
    const direction = forward && !backward ? 1 : -1;
    current = next;
    thumbs.forEach((button, i) => button.setAttribute("aria-pressed", String(i === current)));
    mainCaption.textContent = slide.caption;

    const token = ++switchToken;
    const swap = () => {
      mainImg.src = slide.src;
      mainImg.alt = slide.alt;
      mainImg.width = Number(slide.width);
      mainImg.height = Number(slide.height);
    };
    if (!animate || reduceMotion.matches) { swap(); return; }

    const preload = new Image();
    preload.src = slide.src;
    main.style.setProperty("--shift", `${direction * -24}px`);
    main.classList.add("is-leaving");
    await Promise.all([
      preload.decode().catch(() => {}),
      new Promise((resolve) => setTimeout(resolve, 170)),
    ]);
    if (token !== switchToken) return;
    swap();
    main.style.setProperty("--shift", `${direction * 24}px`);
    main.classList.add("is-entering");
    main.classList.remove("is-leaving");
    // Two frames: the browser must paint the "entering" position before the transition back to 0.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (token === switchToken) main.classList.remove("is-entering");
    }));
  }

  // Arrow keys while focus is on the gallery controls.
  controls.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    show(current + (event.key === "ArrowLeft" ? -1 : 1));
    thumbs[current].focus();
  });

  // Horizontal swipe on the large screenshot (touch screens).
  let startX = null;
  mainImg.addEventListener("pointerdown", (event) => {
    if (event.pointerType === "touch") startX = event.clientX;
  });
  mainImg.addEventListener("pointerup", (event) => {
    if (startX === null) return;
    const dx = event.clientX - startX;
    startX = null;
    if (Math.abs(dx) > 50) show(current + (dx < 0 ? 1 : -1));
  });
  // The browser took the gesture over (e.g. a vertical scroll): forget it.
  mainImg.addEventListener("pointercancel", () => { startX = null; });

  // Warm the cache for the other screenshots once the page is idle, so switching feels instant.
  const warm = () => slides.slice(1).forEach((slide) => { new Image().src = slide.src; });
  if ("requestIdleCallback" in window) requestIdleCallback(warm); else setTimeout(warm, 1500);

  show(0, false);
})();

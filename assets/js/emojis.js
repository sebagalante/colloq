/**
 * Colloq Emoji System
 *
 * Two layers:
 * 1. Twemoji — renders native emojis consistently across all platforms
 *    using Twitter's open-source emoji set.
 * 2. Custom emojis — football-specific emojis uploaded by admins,
 *    rendered via :shortcodes: in posts.
 *
 * Usage in posts:
 *   Native emojis: ⚽ 🏆 🇦🇷 (rendered by Twemoji automatically)
 *   Custom shortcodes: :racing: :gol: :vamos: (replaced with <img> tags)
 */

import twemoji from "@discordapp/twemoji";

// =========================================================================
// Custom emojis — football forum specific
// =========================================================================
// To add more: upload PNG/SVG to priv/static/emojis/ and add an entry here.
// Admins can manage these via the admin panel (future feature).

const CUSTOM_EMOJIS = {
  // Club logos
  racing:    { url: "/emojis/racing.png",    name: "Racing Club" },
  boca:      { url: "/emojis/boca.png",      name: "Boca Juniors" },
  river:     { url: "/emojis/river.png",     name: "River Plate" },
  independiente: { url: "/emojis/independiente.png", name: "Independiente" },
  sanlorenzo:{ url: "/emojis/sanlorenzo.png",name: "San Lorenzo" },

  // Match events
  gol:       { url: "/emojis/gol.png",       name: "Gol" },
  roja:      { url: "/emojis/roja.png",      name: "Tarjeta roja" },
  amarilla:  { url: "/emojis/amarilla.png",  name: "Tarjeta amarilla" },
  var:       { url: "/emojis/var.png",       name: "VAR" },
  penal:     { url: "/emojis/penal.png",     name: "Penal" },

  // Fan culture
  vamos:     { url: "/emojis/vamos.png",     name: "¡Vamos!" },
  daleacademia: { url: "/emojis/daleacademia.png", name: "Dale Academia" },
  escudo:    { url: "/emojis/escudo.png",    name: "Escudo" },
  campeon:   { url: "/emojis/campeon.png",   name: "Campeón" },
};

// =========================================================================
// Twemoji initialization
// =========================================================================

export function initTwemoji() {
  // Twemoji will parse the body on load and replace native emojis
  // with cross-platform consistent <img> tags.
  // We exclude custom emoji shortcodes from Twemoji parsing.
  twemoji.base = "https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/";
  twemoji.ext = ".svg";
  twemoji.size = "72x72";
}

// =========================================================================
// Parse emojis in a DOM element
// =========================================================================

export function parseEmojis(element) {
  if (!element) return;

  // 1. Replace custom :shortcodes: with <img> tags
  replaceCustomEmojis(element);

  // 2. Run Twemoji on the element to render native emojis
  twemoji.parse(element, {
    folder: "svg",
    ext: ".svg",
    base: "https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/",
    callback: (icon, options, variant) => {
      // Skip if this is inside a custom emoji img
      return undefined;
    }
  });
}

// =========================================================================
// Replace :shortcode: patterns with custom emoji <img> tags
// =========================================================================

function replaceCustomEmojis(element) {
  // Only process text nodes
  const walker = document.createTreeWalker(
    element,
    NodeFilter.SHOW_TEXT,
    null,
    false
  );

  const textNodes = [];
  let node;
  while ((node = walker.nextNode())) {
    if (node.textContent.includes(":")) {
      textNodes.push(node);
    }
  }

  const shortcodeRegex = /:([a-z0-9_]+):/g;

  textNodes.forEach((textNode) => {
    const text = textNode.textContent;
    if (!shortcodeRegex.test(text)) return;

    // Reset regex
    shortcodeRegex.lastIndex = 0;

    const fragment = document.createDocumentFragment();
    let lastIndex = 0;
    let match;

    while ((match = shortcodeRegex.exec(text)) !== null) {
      const shortcode = match[1];
      const emoji = CUSTOM_EMOJIS[shortcode];

      if (emoji) {
        // Add text before the shortcode
        if (match.index > lastIndex) {
          fragment.appendChild(
            document.createTextNode(text.slice(lastIndex, match.index))
          );
        }

        // Create emoji <img>
        const img = document.createElement("img");
        img.src = emoji.url;
        img.alt = `:${shortcode}:`;
        img.title = emoji.name;
        img.className = "custom-emoji";
        img.setAttribute("draggable", "false");
        fragment.appendChild(img);

        lastIndex = match.index + match[0].length;
      }
    }

    // Add remaining text
    if (lastIndex < text.length) {
      fragment.appendChild(document.createTextNode(text.slice(lastIndex)));
    }

    // Only replace if we found custom emojis
    if (lastIndex > 0) {
      textNode.parentNode.replaceChild(fragment, textNode);
    }
  });
}

// =========================================================================
// Get custom emojis for picker
// =========================================================================

export function getCustomEmojis() {
  return Object.entries(CUSTOM_EMOJIS).map(([shortcode, data]) => ({
    shortcode,
    ...data,
  }));
}

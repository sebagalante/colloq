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
// Custom emojis — loaded from the database
// =========================================================================
// Populated at boot from /api/emojis, which serves the `custom_emojis` table
// that admins manage in the admin panel.
//
// This used to be a hardcoded map of 14 shortcodes pointing at files in
// priv/static/emojis/. None of those files existed, so every one of them
// rendered as a broken image — while the one emoji an admin had actually
// uploaded wasn't in the map and rendered as literal ":libertadores:" text.
// The uploader wrote to a table nothing read.
let CUSTOM_EMOJIS = {};

/**
 * Fetch the custom emoji map, then re-parse the page.
 *
 * The map arrives after first paint, so anything already rendered has to be
 * parsed again — otherwise shortcodes stay as text until the next LiveView
 * patch happens to touch them.
 */
export async function loadCustomEmojis() {
  try {
    const res = await fetch("/api/emojis", {
      headers: { accept: "application/json" },
      credentials: "same-origin",
    });
    if (!res.ok) return;

    const { emojis } = await res.json();
    CUSTOM_EMOJIS = Object.fromEntries(
      (emojis || []).map((e) => [e.name, { url: e.url, name: e.name }])
    );

    if (Object.keys(CUSTOM_EMOJIS).length) parseEmojis(document.body);
  } catch (_) {
    // A forum that renders shortcodes as plain text is a much smaller failure
    // than one that refuses to boot.
  }
}

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

  // 3. Racing colours: render the red heart ❤️ (2764) as the blue heart 💙
  //    (1f499) — a real emoji image, not a filter hack. Applies to hearts from
  //    any source (keyboard, picker, pasted text).
  recolorHearts(element);
}

function recolorHearts(element) {
  element.querySelectorAll('img.emoji[src*="2764"]').forEach((img) => {
    img.src = img.src.replace(/2764(-fe0f)?\.svg/, "1f499.svg");
    img.alt = "💙";
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

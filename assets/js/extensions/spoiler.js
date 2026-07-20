import { Mark, mergeAttributes } from "@tiptap/core";

/**
 * Tiptap mark for inline spoilers.
 *
 * Wraps a run of inline text in `<span data-spoiler>`. In the composer the
 * text stays readable (dashed underline) so the author can see what they
 * hid; on the rendered post it's blurred until the reader clicks it (see the
 * PostBody hook + the `[data-spoiler]` rules in app.css).
 *
 * The `data-spoiler` attribute is what survives the server-side HTML
 * sanitizer (a class would be stripped), so the reveal behaviour keys off it.
 */
const Spoiler = Mark.create({
  name: "spoiler",
  inclusive: false,

  parseHTML() {
    return [{ tag: "span[data-spoiler]" }];
  },

  renderHTML({ HTMLAttributes }) {
    return [
      "span",
      mergeAttributes(HTMLAttributes, {
        "data-spoiler": "",
        class: "tiptap-spoiler",
      }),
      0,
    ];
  },

  addCommands() {
    return {
      setSpoiler: () => ({ commands }) => commands.setMark(this.name),
      toggleSpoiler: () => ({ commands }) => commands.toggleMark(this.name),
      unsetSpoiler: () => ({ commands }) => commands.unsetMark(this.name),
    };
  },
});

export default Spoiler;

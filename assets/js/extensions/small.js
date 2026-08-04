import { Mark, mergeAttributes } from "@tiptap/core";

/**
 * Tiptap mark for small print.
 *
 * Wraps a run of inline text in `<small>`. This is the only inline size
 * control that survives the server-side sanitizer: `span[style]` is stripped
 * (span's attribute allowlist in the html5 scrubber has no `style`), so a
 * font-size mark would silently vanish on save, while `<small>` is on the
 * allowlist. Sized in `em` in app.css so it shrinks relative to whatever
 * block it sits in rather than to a fixed pixel size.
 */
const Small = Mark.create({
  name: "small",

  parseHTML() {
    return [{ tag: "small" }];
  },

  renderHTML({ HTMLAttributes }) {
    return ["small", mergeAttributes(HTMLAttributes), 0];
  },

  addCommands() {
    return {
      setSmall: () => ({ commands }) => commands.setMark(this.name),
      toggleSmall: () => ({ commands }) => commands.toggleMark(this.name),
      unsetSmall: () => ({ commands }) => commands.unsetMark(this.name),
    };
  },
});

export default Small;

import { Node, mergeAttributes } from "@tiptap/core";

/**
 * Tiptap extension for poll placeholders in the editor.
 *
 * Polls are stored as separate entities (polls/poll_options/poll_votes tables)
 * linked to a post. This extension renders a non-editable placeholder block
 * in the editor that shows "📊 Poll: <question>" when a poll is attached.
 *
 * The actual poll data lives in the database, not in the Tiptap document.
 * This node only provides visual feedback in the editor.
 */
const PollNode = Node.create({
  name: "poll",
  group: "block",
  atom: true,
  draggable: false,

  addAttributes() {
    return {
      question: {
        default: null,
      },
      pollId: {
        default: null,
      },
    };
  },

  parseHTML() {
    return [
      {
        tag: 'div[data-type="poll"]',
      },
    ];
  },

  renderHTML({ HTMLAttributes }) {
    return [
      "div",
      mergeAttributes(HTMLAttributes, {
        "data-type": "poll",
        class:
          "poll-placeholder my-4 p-4 rounded-lg bg-blue-900/20 border border-blue-700/40 flex items-center gap-3",
      }),
      [
        "span",
        { class: "text-blue-400 text-lg" },
        "📊",
      ],
      [
        "span",
        { class: "text-sm text-blue-300 font-medium" },
        HTMLAttributes.question || "Encuesta adjunta",
      ],
    ];
  },

  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement("div");
      dom.setAttribute("data-type", "poll");
      dom.className =
        "poll-placeholder my-4 p-4 rounded-lg bg-blue-900/20 border border-blue-700/40 flex items-center gap-3 select-none";
      dom.contentEditable = "false";

      const icon = document.createElement("span");
      icon.className = "text-blue-400 text-lg";
      icon.textContent = "📊";

      const text = document.createElement("span");
      text.className = "text-sm text-blue-300 font-medium";
      text.textContent = node.attrs.question || "Encuesta adjunta";

      dom.appendChild(icon);
      dom.appendChild(text);

      return { dom };
    };
  },

  addCommands() {
    return {
      insertPoll:
        (question) =>
        ({ commands }) => {
          return commands.insertContent({
            type: this.name,
            attrs: { question },
          });
        },
    };
  },
});

export default PollNode;

// Colloq — LiveView Hooks
// EmojiPicker, PostImpression, AutoScroll, PushSubscription,
// VoiceRoom, TiptapEditor

let Hooks = {};

// =========================================================================
// EmojiPicker — Selector de emoji con sprites WebP estilo Noto
// =========================================================================
Hooks.EmojiPicker = {
  mounted() {
    this.pickerVisible = false;
    this.emojiCategories = this.el.dataset.emojiCategories
      ? JSON.parse(this.el.dataset.emojiCategories)
      : [
          { name: "Reacciones", emojis: ["👍", "❤️", "😂", "😮", "😢", "😡"] },
          { name: "Fútbol", emojis: ["⚽", "🏆", "🔵", "⚪", "💙", "🤍"] },
          { name: "Gestos", emojis: ["👏", "🙌", "🔥", "💯", "🤝", "🎉"] }
        ];
    this.renderPicker();
    document.addEventListener("click", this.handleOutsideClick.bind(this));
  },

  destroyed() {
    document.removeEventListener("click", this.handleOutsideClick.bind(this));
    this.removePicker();
  },

  renderPicker() {
    let picker = document.createElement("div");
    picker.className = "emoji-picker-dropdown";
    picker.style.cssText = `
      position: absolute; z-index: 100; background: #1e293b;
      border: 1px solid #334155; border-radius: 12px;
      padding: 12px; box-shadow: 0 10px 40px rgba(0,0,0,0.5);
      min-width: 300px; display: none;
    `;

    this.emojiCategories.forEach((cat) => {
      let section = document.createElement("div");
      section.style.marginBottom = "8px";

      let label = document.createElement("div");
      label.textContent = cat.name;
      label.style.cssText = "font-size: 11px; color: #94a3b8; margin-bottom: 4px; text-transform: uppercase; letter-spacing: 0.05em;";
      section.appendChild(label);

      let grid = document.createElement("div");
      grid.style.cssText = "display: grid; grid-template-columns: repeat(6, 1fr); gap: 4px;";

      cat.emojis.forEach((emoji) => {
        let btn = document.createElement("button");
        btn.textContent = emoji;
        btn.style.cssText = `
          font-size: 28px; background: transparent; border: none;
          cursor: pointer; padding: 4px; border-radius: 8px;
          transition: background 0.15s; line-height: 1;
        `;
        btn.onmouseenter = () => (btn.style.background = "#334155");
        btn.onmouseleave = () => (btn.style.background = "transparent");
        btn.onclick = (e) => {
          e.stopPropagation();
          this.pushEvent("emoji-selected", { emoji });
          this.hidePicker();
        };
        grid.appendChild(btn);
      });

      section.appendChild(grid);
      picker.appendChild(section);
    });

    this.el.appendChild(picker);
    this.pickerEl = picker;

    this.el.addEventListener("mouseenter", () => this.showPicker());
    this.el.addEventListener("mouseleave", (e) => {
      if (!this.pickerEl.contains(e.relatedTarget)) this.hidePicker();
    });
    this.pickerEl.addEventListener("mouseleave", (e) => {
      if (!this.el.contains(e.relatedTarget)) this.hidePicker();
    });
  },

  showPicker() {
    if (this.pickerEl) this.pickerEl.style.display = "block";
  },

  hidePicker() {
    if (this.pickerEl) this.pickerEl.style.display = "none";
  },

  handleOutsideClick(e) {
    if (this.pickerEl && !this.el.contains(e.target)) {
      this.hidePicker();
    }
  },

  removePicker() {
    if (this.pickerEl) this.pickerEl.remove();
  }
};

// =========================================================================
// PostImpression — Contador de vistas por IntersectionObserver
// =========================================================================
Hooks.PostImpression = {
  mounted() {
    const postId = this.el.dataset.postId;
    if (!postId) return;

    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) {
        this.pushEvent("view-post", { id: postId });
        observer.unobserve(this.el);
      }
    }, { threshold: 0.5 });

    observer.observe(this.el);
  }
};

// =========================================================================
// AutoScroll — Modo live de día de partido
// =========================================================================
Hooks.AutoScroll = {
  mounted() {
    this.scrollToBottom();
    this.observer = new MutationObserver(() => this.scrollToBottom());
    this.observer.observe(this.el, { childList: true, subtree: true });
    this.handleScrollEvent = () => {
      const atBottom = window.innerHeight + window.scrollY >= document.body.scrollHeight - 200;
      this.el.dataset.following = atBottom ? "true" : "false";
    };
    window.addEventListener("scroll", this.handleScrollEvent);
  },

  destroyed() {
    if (this.observer) this.observer.disconnect();
    window.removeEventListener("scroll", this.handleScrollEvent);
  },

  scrollToBottom() {
    if (this.el.dataset.following === "true") {
      window.scrollTo({ top: document.body.scrollHeight, behavior: "smooth" });
    }
  }
};

// =========================================================================
// PushSubscription — Registro de notificaciones push web
// =========================================================================
Hooks.PushSubscription = {
  mounted() {
    if (!("Notification" in window) || !("serviceWorker" in navigator)) return;

    const vapidKey = this.el.dataset.vapidPublicKey;
    if (!vapidKey) return;

    Notification.requestPermission().then((permission) => {
      if (permission !== "granted") return;

      navigator.serviceWorker.ready.then((registration) => {
        return registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(vapidKey)
        });
      }).then((subscription) => {
        if (!subscription) return;

        this.pushEvent("push-subscribe", {
          endpoint: subscription.endpoint,
          keys: {
            p256dh: btoa(String.fromCharCode(...new Uint8Array(subscription.getKey("p256dh")))),
            auth: btoa(String.fromCharCode(...new Uint8Array(subscription.getKey("auth"))))
          }
        });
      }).catch((err) => console.error("[Colloq] Error suscripción push:", err));
    });
  }
};

// =========================================================================
// VoiceRoom — WebRTC + VAD para sala de voz
// =========================================================================
Hooks.VoiceRoom = {
  mounted() {
    this.peerConnections = {};
    this.localStream = null;
    this.audioContext = null;
    this.isSpeaking = false;

    this.handleEvent("voice-join", ({ room_id }) => this.joinRoom(room_id));
    this.handleEvent("voice-leave", () => this.leaveRoom());
    this.handleEvent("voice-signal", ({ peer_id, signal }) => this.handleSignal(peer_id, signal));
  },

  destroyed() {
    this.leaveRoom();
  },

  async joinRoom(roomId) {
    try {
      this.localStream = await navigator.mediaDevices.getUserMedia({ audio: true });
      this.setupVAD(this.localStream);
      this.pushEvent("voice-ready", { room_id: roomId });
    } catch (err) {
      console.error("[VoiceRoom] Error accediendo al micrófono:", err);
    }
  },

  leaveRoom() {
    Object.values(this.peerConnections).forEach((pc) => pc.close());
    this.peerConnections = {};

    if (this.localStream) {
      this.localStream.getTracks().forEach((t) => t.stop());
      this.localStream = null;
    }

    if (this.audioContext) {
      this.audioContext.close();
      this.audioContext = null;
    }
  },

  async handleSignal(peerId, signal) {
    let pc = this.peerConnections[peerId];
    const rtcConfig = { iceServers: [{ urls: "stun:stun.l.google.com:19302" }] };

    if (!pc) {
      pc = new RTCPeerConnection(rtcConfig);
      this.peerConnections[peerId] = pc;

      pc.onicecandidate = (e) => {
        if (e.candidate) {
          this.pushEvent("voice-signal", { peer_id: peerId, signal: e.candidate });
        }
      };

      pc.ontrack = (e) => {
        const audio = new Audio();
        audio.srcObject = e.streams[0];
        audio.play();
      };

      if (this.localStream) {
        this.localStream.getTracks().forEach((t) => pc.addTrack(t, this.localStream));
      }
    }

    if (signal.type === "offer") {
      await pc.setRemoteDescription(new RTCSessionDescription(signal));
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      this.pushEvent("voice-signal", { peer_id: peerId, signal: pc.localDescription });
    } else if (signal.type === "answer") {
      await pc.setRemoteDescription(new RTCSessionDescription(signal));
    } else if (signal.candidate) {
      await pc.addIceCandidate(new RTCIceCandidate(signal));
    }
  },

  setupVAD(stream) {
    this.audioContext = new (window.AudioContext || window.webkitAudioContext)();
    const source = this.audioContext.createMediaStreamSource(stream);
    const analyser = this.audioContext.createAnalyser();
    analyser.fftSize = 256;
    source.connect(analyser);

    const bufferLength = analyser.frequencyBinCount;
    const dataArray = new Uint8Array(bufferLength);

    const checkSpeaking = () => {
      if (!this.audioContext) return;
      analyser.getByteFrequencyData(dataArray);
      const avg = dataArray.reduce((a, b) => a + b, 0) / bufferLength;
      const speaking = avg > 30;

      if (speaking !== this.isSpeaking) {
        this.isSpeaking = speaking;
        this.pushEvent("voice-speaking", { speaking });
      }

      requestAnimationFrame(checkSpeaking);
    };

    checkSpeaking();
  }
};

// =========================================================================
// TiptapEditor — Integración Tiptap v3
// =========================================================================
Hooks.TiptapEditor = {
  mounted() {
    this.editor = null;
    this.setupTiptap();
  },

  destroyed() {
    if (this.editor) {
      this.editor.destroy();
      this.editor = null;
    }
  },

  async setupTiptap() {
    if (typeof window.TiptapEditor === "undefined") {
      this.el.contentEditable = "true";
      this.el.addEventListener("input", () => {
        this.pushEvent("editor-input", {
          body: this.el.innerHTML,
          body_json: null
        });
      });
      return;
    }

    try {
      const { Editor } = await import("@tiptap/core");
      const StarterKit = (await import("@tiptap/starter-kit")).default;
      const Placeholder = (await import("@tiptap/extension-placeholder")).default;
      const Image = (await import("@tiptap/extension-image")).default;
      const LinkExtension = (await import("@tiptap/extension-link")).default;

      this.editor = new Editor({
        element: this.el,
        extensions: [
          StarterKit,
          Placeholder.configure({
            placeholder: "Escribí tu post..."
          }),
          Image.configure({ inline: true }),
          LinkExtension.configure({ openOnClick: false })
        ],
        content: this.el.dataset.content || "",
        onUpdate: ({ editor }) => {
          this.pushEvent("editor-input", {
            body: editor.getHTML(),
            body_json: editor.getJSON()
          });
        }
      });
    } catch (err) {
      console.error("[TiptapEditor] Error inicializando:", err);
    }
  }
};

// =========================================================================
// Utility: urlBase64ToUint8Array
// =========================================================================
function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - base64String.length % 4) % 4);
  const base64 = (base64String + padding).replace(/\-/g, "+").replace(/_/g, "/");
  const rawData = atob(base64);
  return new Uint8Array([...rawData].map((char) => char.charCodeAt(0)));
}

// =========================================================================
// Export
// =========================================================================
export default Hooks;

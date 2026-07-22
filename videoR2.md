# Serving Video on R2 — Size Limits

**Short answer:** R2 will take a single video up to ~5 GB, but the app today
caps it far lower — around **8 MB in practice** — and the current R2 code isn't
built to serve large video safely. The limit depends on which layer you hit
first. Below, smallest-binding first.

## 1. App's own limits (these bind first)

| Path | Coded limit | Accepts video? |
|---|---|---|
| Composer image (`lib/colloq_web/controllers/upload_controller.ex:11`) | **5 MB** | no — image types only |
| Chat attachment (`upload_controller.ex:27`) | **15 MB** | yes — "any file type" |
| LiveView uploads (avatar / profile / stickers) | 1–5 MB | no — image types |

Today the **only** path a video can take is the **chat attachment**, coded at
15 MB.

## 2. Plug quietly caps it lower (~8 MB)

`lib/colloq_web/endpoint.ex:43` uses `Plug.Parsers` with **no `:length`
override**, so multipart bodies fall back to Plug's default **8 MB**. The
chat-attachment controller is a plain multipart POST, so a request over 8 MB is
rejected by Plug *before* the 15 MB check ever runs.

**Effective video limit right now ≈ 8 MB.**

(LiveView uploads bypass this — they stream over the socket — but none of those
accept video.)

## 3. The R2 adapter itself isn't video-ready

`lib/colloq/media/r2.ex` does `File.read!(tmp)` — it loads the **entire file
into memory** — then one `put_object`. Fine for tens of MB; a real video
(hundreds of MB) risks OOM, especially with concurrent uploads. It's a
single-PUT with no multipart/streaming.

## 4. R2's own protocol limit (the actual ceiling)

- **Single `PutObject`** (what the adapter uses): up to **~5 GiB** per object.
- **Larger than that** needs **multipart upload** (not implemented) — R2 objects
  can go up to ~4.995 **TiB**.

## To actually serve video, you'd need to

1. Raise the app limits (the 5 MB / 15 MB constants) **and** set `Plug.Parsers`
   `:length` on the video route — or better, upload video **directly to R2 from
   the browser via a presigned URL**, bypassing the server entirely.
2. Avoid `File.read!` for big files — stream / multipart, or (again) presigned
   direct-to-R2, so the server never buffers the video.

**For anything beyond ~50 MB, presigned direct upload is the right
architecture** — the file goes browser → R2, and the app only signs the request.
